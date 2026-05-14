import json
import os
import time
from threading import Lock
from typing import Any, Dict, Optional, Tuple
from urllib.parse import urlparse

import boto3
from fastapi import HTTPException
from litellm._logging import verbose_proxy_logger
from litellm.caching.caching import DualCache
from litellm.integrations.custom_logger import CustomLogger
from litellm.proxy._types import UserAPIKeyAuth
from litellm.types.utils import CallTypesLiteral


class DynamicBackendApiKeyHook(CustomLogger):
    def __init__(self) -> None:
        self._cache: Dict[str, Tuple[float, str]] = {}
        self._cache_lock = Lock()
        self._secrets_client = None
        self._ttl_sec = max(0, int(os.getenv("SECRET_CACHE_TTL_SEC", "60")))
        self._aws_region = (
            os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION") or "ap-northeast-1"
        )
        self._secrets_name_prefix = os.getenv("SECRETS_NAME_PREFIX", "")
        self._inline_secret_map = self._load_inline_secret_map()

    async def async_pre_call_hook(
        self,
        user_api_key_dict: UserAPIKeyAuth,
        cache: DualCache,
        data: dict,
        call_type: CallTypesLiteral,
    ):
        if not isinstance(data, dict):
            return data

        route_context = self._resolve_route_context(call_type=call_type, data=data)
        if route_context is None:
            return data

        secret_id = self._resolve_secret_id(
            user_api_key_dict=user_api_key_dict,
            data=data,
            strict=route_context["strict_secret_resolution"],
        )
        if secret_id is None:
            return data

        try:
            provider_api_key = self._get_provider_api_key(secret_id=secret_id)
        except HTTPException as exc:
            if "format is invalid" in str(exc.detail):
                verbose_proxy_logger.error(
                    "DynamicBackendApiKeyHook secret format is invalid. secret_id=%s call_type=%s",
                    secret_id,
                    call_type,
                )
            elif "Failed to read secret" in str(exc.detail):
                verbose_proxy_logger.error(
                    "DynamicBackendApiKeyHook failed to read secret. secret_id=%s call_type=%s",
                    secret_id,
                    call_type,
                )
            raise

        route_label = route_context["route_label"]
        if route_label == "pass-through" and call_type == "pass_through_endpoint":
            metadata = self._extract_metadata_from_request(data)
            metadata["secret_id"] = secret_id
            metadata["__dynamic_secret_required"] = True
            data["metadata"] = metadata
            verbose_proxy_logger.debug(
                "DynamicBackendApiKeyHook validated pass-through secret route=%s call_type=%s key_alias=%s",
                route_label,
                call_type,
                self._resolve_virtual_key_id(user_api_key_dict),
            )
            return data

        if route_label == "pass-through":
            requested_model = str(data.get("model", ""))
            if requested_model == "openai.mock-gpt-4o-mini":
                data["model"] = "openai/gpt-4o-mini"
                openai_mock_api_base = os.getenv("OPENAI_MOCK_API_BASE")
                if isinstance(openai_mock_api_base, str) and openai_mock_api_base:
                    data["api_base"] = openai_mock_api_base

        data["api_key"] = provider_api_key
        extra_headers = data.get("extra_headers")
        if not isinstance(extra_headers, dict):
            extra_headers = {}
        extra_headers["Authorization"] = f"Bearer {provider_api_key}"
        data["extra_headers"] = extra_headers

        verbose_proxy_logger.debug(
            "DynamicBackendApiKeyHook applied key swap route=%s call_type=%s key_alias=%s",
            route_label,
            call_type,
            self._resolve_virtual_key_id(user_api_key_dict),
        )
        return data

    def _resolve_route_context(
        self,
        call_type: CallTypesLiteral,
        data: Dict[str, Any],
    ) -> Optional[Dict[str, Any]]:
        if call_type == "pass_through_endpoint":
            metadata = self._extract_metadata_from_request(data)
            if metadata.get("pass_through_dynamic_secret") is not True:
                return None
            return {
                "route_label": "pass-through",
                "strict_secret_resolution": True,
            }

        model = str(data.get("model", ""))
        is_openai_compatible_model = model.startswith("openai/") or model.startswith("openai.")
        if not is_openai_compatible_model:
            return None

        proxy_request = data.get("proxy_server_request")
        if isinstance(proxy_request, dict):
            request_url = proxy_request.get("url")
            if isinstance(request_url, str):
                parsed = urlparse(request_url)
                if parsed.path.startswith("/pt/dynamic/"):
                    return {
                        "route_label": "pass-through",
                        "strict_secret_resolution": True,
                    }
        return {
            "route_label": "openai-model",
            "strict_secret_resolution": False,
        }

    def _load_inline_secret_map(self) -> Dict[str, Any]:
        raw = os.getenv("LITELLM_SECRET_MAP_JSON")
        if not raw:
            return {}
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                return parsed
        except json.JSONDecodeError:
            verbose_proxy_logger.error(
                "LITELLM_SECRET_MAP_JSON is not valid JSON. Falling back to AWS Secrets Manager."
            )
        return {}

    def _resolve_virtual_key_id(self, user_api_key_dict: UserAPIKeyAuth) -> str:
        for field_name in ("key_alias", "key_name", "token", "api_key"):
            value = getattr(user_api_key_dict, field_name, None)
            if isinstance(value, str) and value:
                return value
        return "unknown-key"

    def _resolve_secret_id(
        self,
        user_api_key_dict: UserAPIKeyAuth,
        data: Dict[str, Any],
        strict: bool,
    ) -> Optional[str]:
        metadata_from_request = self._extract_metadata_from_request(data)
        if isinstance(metadata_from_request, dict):
            for key in ("secret_id", "backend_secret_id", "provider_secret_id"):
                value = metadata_from_request.get(key)
                if isinstance(value, str) and value:
                    return value

        metadata = getattr(user_api_key_dict, "metadata", None) or {}
        if isinstance(metadata, dict):
            for key in ("secret_id", "backend_secret_id", "provider_secret_id"):
                value = metadata.get(key)
                if isinstance(value, str) and value:
                    return value

        if strict:
            verbose_proxy_logger.error(
                "DynamicBackendApiKeyHook missing secret_id for strict route. key_alias=%s",
                self._resolve_virtual_key_id(user_api_key_dict),
            )
            raise HTTPException(
                status_code=403,
                detail=(
                    "No secret mapping found. Set key metadata.secret_id "
                    "or configure SECRETS_NAME_PREFIX."
                ),
            )

        if self._secrets_name_prefix:
            return f"{self._secrets_name_prefix}{self._resolve_virtual_key_id(user_api_key_dict)}"

        return None

    def _extract_metadata_from_request(self, data: Dict[str, Any]) -> Dict[str, Any]:
        metadata = data.get("metadata")
        if isinstance(metadata, dict):
            return metadata

        proxy_request = data.get("proxy_server_request")
        if isinstance(proxy_request, dict):
            body = proxy_request.get("body")
            if isinstance(body, dict):
                nested = body.get("metadata")
                if isinstance(nested, dict):
                    return nested

        return {}

    def _get_provider_api_key(self, secret_id: str) -> str:
        cached = self._read_from_cache(secret_id)
        if cached is not None:
            return cached

        if secret_id in self._inline_secret_map:
            api_key = self._extract_api_key(self._inline_secret_map[secret_id])
            self._write_to_cache(secret_id=secret_id, api_key=api_key)
            return api_key

        secret_value = self._get_secret_value_from_aws(secret_id=secret_id)
        api_key = self._extract_api_key(secret_value)
        self._write_to_cache(secret_id=secret_id, api_key=api_key)
        return api_key

    def _read_from_cache(self, secret_id: str) -> Optional[str]:
        if self._ttl_sec == 0:
            return None

        now = time.time()
        with self._cache_lock:
            cache_entry = self._cache.get(secret_id)
            if cache_entry is None:
                return None
            expires_at, api_key = cache_entry
            if expires_at <= now:
                self._cache.pop(secret_id, None)
                return None
            return api_key

    def _write_to_cache(self, secret_id: str, api_key: str) -> None:
        if self._ttl_sec == 0:
            return
        expires_at = time.time() + self._ttl_sec
        with self._cache_lock:
            self._cache[secret_id] = (expires_at, api_key)

    def _get_secret_value_from_aws(self, secret_id: str) -> Any:
        if self._secrets_client is None:
            self._secrets_client = boto3.client(
                "secretsmanager",
                region_name=self._aws_region,
            )
        try:
            response = self._secrets_client.get_secret_value(SecretId=secret_id)
        except Exception as exc:
            raise HTTPException(
                status_code=403,
                detail=f"Failed to read secret '{secret_id}': {type(exc).__name__}",
            ) from exc

        if "SecretString" in response:
            return response["SecretString"]
        if "SecretBinary" in response:
            secret_binary = response["SecretBinary"]
            if isinstance(secret_binary, bytes):
                return secret_binary.decode("utf-8")
            return secret_binary

        raise HTTPException(
            status_code=403,
            detail=f"Secret '{secret_id}' has no SecretString/SecretBinary.",
        )

    def _extract_api_key(self, raw_value: Any) -> str:
        if isinstance(raw_value, dict):
            for key_name in ("provider_api_key", "api_key", "token", "value"):
                candidate = raw_value.get(key_name)
                if isinstance(candidate, str) and candidate:
                    return candidate

        if isinstance(raw_value, str):
            stripped = raw_value.strip()
            if not stripped:
                raise HTTPException(status_code=403, detail="Secret value is empty.")
            if stripped.startswith("{"):
                try:
                    parsed_json = json.loads(stripped)
                    return self._extract_api_key(parsed_json)
                except json.JSONDecodeError:
                    # JSONでなければ平文キーとして扱う
                    return stripped
            return stripped

        raise HTTPException(
            status_code=403,
            detail="Secret value format is invalid. Expected string or JSON object.",
        )


class PassThroughOpenAIAdapter(CustomLogger):
    """Identity adapter for pass_through_endpoints -> LiteLLM chat completion."""

    def translate_completion_input_params(self, kwargs):
        return kwargs

    def translate_completion_output_params(self, response):
        return response

    def translate_completion_output_params_streaming(self, completion_stream):
        return completion_stream


proxy_handler_instance = DynamicBackendApiKeyHook()
pass_through_openai_adapter = PassThroughOpenAIAdapter()
