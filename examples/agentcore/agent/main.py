"""A Strands agent for Amazon Bedrock AgentCore Runtime that does all of its LLM
inference through the LiteLLM gateway.

The model is reached through the gateway's OpenAI-compatible API with the
agent's own LiteLLM virtual key, so the key's model list, budget, rate limits,
guardrails and logging apply to the agent exactly as to any other client. The
runtime role has no Amazon Bedrock permissions, so the agent reaches models
through the gateway.

The virtual key is not in the environment or the code package. AgentCore
Identity holds it (an API-key credential provider backed by a Secrets Manager
secret) and returns it per request, in exchange for the workload access token
AgentCore Runtime issues for the invocation.

Configuration (environment variables, set by the Terraform in this example):
  GATEWAY_BASE_URL     the gateway URL, for example https://llm.example.com
  MODEL_ID             a model name registered in the gateway
  CREDENTIAL_PROVIDER  the AgentCore Identity API-key credential provider name
  MAX_TOKENS           optional output-token cap per model call (default 1024)
  GATEWAY_CA_PEM_BASE64  optional base64-encoded PEM certificate(s) of a private
                       certificate authority that issued the gateway's
                       certificate; trusted in addition to the public roots
"""

from __future__ import annotations

import base64
import os
import ssl
from collections.abc import Awaitable, Callable
from typing import Any

import openai
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from strands import Agent, tool
from strands.models.openai import OpenAIModel
from strands.types.exceptions import ModelThrottledException

SYSTEM_PROMPT = "You are a concise assistant. Use the word_count tool whenever the user asks how many words a text has."

app = BedrockAgentCoreApp()

_key_fetcher: Callable[[], Awaitable[str]] | None = None


@tool
def word_count(text: str) -> int:
    """Count the words in a text.

    Args:
        text: The text to count the words of.
    """
    return len(text.split())


def gateway_settings() -> dict[str, Any]:
    """Read and validate the agent's configuration from the environment."""
    base_url = os.environ["GATEWAY_BASE_URL"].rstrip("/")
    if not base_url.startswith(("http://", "https://")):
        raise ValueError("GATEWAY_BASE_URL must start with http:// or https://")
    return {
        "base_url": base_url,
        "model_id": os.environ["MODEL_ID"],
        "credential_provider": os.environ["CREDENTIAL_PROVIDER"],
        "max_tokens": int(os.environ.get("MAX_TOKENS", "1024")),
        "ca_pem": _ca_pem_from_env(),
    }


def _ca_pem_from_env() -> str | None:
    encoded = os.environ.get("GATEWAY_CA_PEM_BASE64")
    return base64.b64decode(encoded).decode("ascii") if encoded else None


def tls_context(ca_pem: str) -> ssl.SSLContext:
    """The public roots plus the gateway's private certificate authority."""
    import certifi

    context = ssl.create_default_context(cafile=certifi.where())
    context.load_verify_locations(cadata=ca_pem)
    return context


def build_model(settings: dict[str, Any], api_key: str, http_client: Any = None) -> OpenAIModel:
    """An OpenAI-compatible model client pointed at the gateway.

    With an http_client (a private CA), the OpenAI client is built here and
    injected: Strands keeps an injected client open across the model calls of
    an invocation, whereas a client built from client_args is closed after each
    call, which would also close the shared http_client.
    """
    client_args: dict[str, Any] = {
        "base_url": f"{settings['base_url']}/v1",
        "api_key": api_key,
        "timeout": 120,
        "max_retries": 2,
    }
    common: dict[str, Any] = {"model_id": settings["model_id"], "params": {"max_tokens": settings["max_tokens"]}}
    if http_client is not None:
        return OpenAIModel(client=openai.AsyncOpenAI(**client_args, http_client=http_client), **common)
    return OpenAIModel(client_args=client_args, **common)


def key_fetcher(provider_name: str) -> Callable[[], Awaitable[str]]:
    """An async function returning the gateway key from AgentCore Identity.

    Built lazily so that importing this module needs no AWS access.
    """
    global _key_fetcher
    if _key_fetcher is None:
        from bedrock_agentcore.identity.auth import requires_api_key

        @requires_api_key(provider_name=provider_name)
        async def fetch(*, api_key: str) -> str:
            return api_key

        _key_fetcher = fetch
    return _key_fetcher


def build_agent(settings: dict[str, Any], api_key: str, http_client: Any = None) -> Agent:
    return Agent(
        model=build_model(settings, api_key, http_client),
        tools=[word_count],
        system_prompt=SYSTEM_PROMPT,
        callback_handler=None,
    )


@app.entrypoint
async def invoke(payload: dict[str, Any], context: Any = None) -> dict[str, Any]:
    prompt = payload.get("prompt") if isinstance(payload, dict) else None
    if not isinstance(prompt, str) or not prompt.strip():
        return {"error": 'The payload must be a JSON object with a non-empty "prompt" string.'}

    settings = gateway_settings()
    try:
        api_key = await key_fetcher(settings["credential_provider"])()
    except ValueError as e:
        # No workload access token: the caller signed the request with SigV4
        # but gave no runtime user ID (runtimeUserId).
        return {"error": f"Could not obtain the gateway key from AgentCore Identity: {e}"}

    # One HTTP client per invocation when the gateway needs a private CA; closed below.
    http_client = openai.DefaultAsyncHttpxClient(verify=tls_context(settings["ca_pem"])) if settings["ca_pem"] else None
    try:
        result = await build_agent(settings, api_key, http_client).invoke_async(prompt)
    except ModelThrottledException as e:
        return {"error": f"The gateway throttled the agent (rate limit): {e}"}
    except openai.APIStatusError as e:
        # The gateway's verdict, for example an exhausted budget or a model the
        # agent's key may not use.
        return {"error": f"The gateway rejected the request (HTTP {e.status_code}): {e.message}"}
    finally:
        if http_client is not None:
            await http_client.aclose()
    return {
        "result": str(result).strip(),
        "model": settings["model_id"],
        "usage": result.metrics.accumulated_usage,
    }


if __name__ == "__main__":
    app.run()
