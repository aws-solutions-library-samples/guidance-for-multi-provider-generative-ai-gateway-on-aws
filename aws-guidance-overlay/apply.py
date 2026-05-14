#!/usr/bin/env python3
"""Apply the LiteLLM dynamic provider-secret hook to an AWS Guidance checkout."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


ROOT = Path(__file__).resolve().parents[1]
SOURCE_HOOK = ROOT / "config" / "custom_secret_manager.py"


class ApplyError(RuntimeError):
    pass


def read_text(path: Path) -> str:
    if not path.exists():
        raise ApplyError(f"Required file not found: {path}")
    return path.read_text(encoding="utf-8")


def write_if_changed(path: Path, content: str, check: bool) -> bool:
    original = read_text(path)
    if original == content:
        return False
    if not check:
        path.write_text(content, encoding="utf-8")
    return True


def ensure_lines_after_from(dockerfile: Path, check: bool) -> bool:
    text = read_text(dockerfile)
    lines = text.splitlines()

    additions = [
        "RUN pip install --no-cache-dir boto3",
        "COPY custom_secret_manager.py /app/custom_secret_manager.py",
        'ENV PYTHONPATH="/app:${PYTHONPATH}"',
    ]
    missing = [line for line in additions if line not in lines]
    if not missing:
        return False

    insert_at = None
    for index, line in enumerate(lines):
        if line.startswith("FROM "):
            insert_at = index + 1
            break
    if insert_at is None:
        raise ApplyError(f"No FROM line found in {dockerfile}")

    next_lines = lines[:insert_at] + missing + lines[insert_at:]
    return write_if_changed(dockerfile, "\n".join(next_lines) + "\n", check)


def find_top_level_section(lines: List[str], section_name: str) -> Tuple[int, int]:
    start = None
    for index, line in enumerate(lines):
        if line == f"{section_name}:":
            start = index
            break
    if start is None:
        raise ApplyError(f"Top-level YAML section not found: {section_name}")

    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line and not line.startswith((" ", "#")):
            end = index
            break
    return start, end


def ensure_litellm_callback(config_file: Path, check: bool) -> bool:
    text = read_text(config_file)
    callback = "custom_secret_manager.proxy_handler_instance"
    if callback in text:
        return False

    lines = text.splitlines()
    start, end = find_top_level_section(lines, "litellm_settings")

    callbacks_line = None
    for index in range(start + 1, end):
        if lines[index].strip() == "callbacks:":
            callbacks_line = index
            break

    if callbacks_line is not None:
        insert_at = callbacks_line + 1
        while insert_at < end and lines[insert_at].startswith("    - "):
            insert_at += 1
        lines.insert(insert_at, f"    - {callback}")
    else:
        lines.insert(start + 1, "  callbacks:")
        lines.insert(start + 2, f"    - {callback}")

    return write_if_changed(config_file, "\n".join(lines) + "\n", check)


def ensure_iam_provider_secret_access(iam_file: Path, check: bool) -> bool:
    text = read_text(iam_file)
    changed = False

    caller_identity = 'data "aws_caller_identity" "current" {}'
    if caller_identity not in text:
        text = caller_identity + "\n\n" + text
        changed = True

    statement = '''  statement {
    sid       = "ProviderSecretRead"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:litellm/provider/*"
    ]
  }

'''
    if 'sid       = "ProviderSecretRead"' not in text:
        anchor = '''  statement {
    sid       = "SageMakerInvoke"
    actions   = ["sagemaker:InvokeEndpoint"]
    resources = ["*"]
  }
'''
        if anchor not in text:
            raise ApplyError(
                "Could not find SageMakerInvoke statement in ECS task role policy. "
                "Apply ProviderSecretRead manually."
            )
        text = text.replace(anchor, anchor + "\n" + statement, 1)
        changed = True

    if not changed:
        return False
    return write_if_changed(iam_file, text, check)


def _normalize_mock_backend_url(mock_backend_url: str) -> str:
    stripped = mock_backend_url.strip()
    if not stripped:
        raise ApplyError("--mock-backend-url must be a non-empty URL.")
    return stripped.rstrip("/")


def ensure_validation_model(
    config_file: Path,
    check: bool,
    mock_backend_url: str,
) -> bool:
    text = read_text(config_file)
    model_marker = 'model_name: openai.mock-gpt-4o-mini'
    if model_marker in text:
        return False

    lines = text.splitlines()
    start, end = find_top_level_section(lines, "model_list")
    mock_v1_base = f"{_normalize_mock_backend_url(mock_backend_url)}/v1"
    block = [
        "  - model_name: openai.mock-gpt-4o-mini",
        "    litellm_params:",
        "      model: openai/gpt-4o-mini",
        f'      api_base: "{mock_v1_base}"',
        '      api_key: "validation-dummy-key"',
    ]
    lines[end:end] = block + [""]
    return write_if_changed(config_file, "\n".join(lines) + "\n", check)


def _find_general_settings_subsection(
    lines: List[str], subsection: str
) -> Tuple[int, int, int, int]:
    """
    Returns:
      general_settings_start, general_settings_end, subsection_start, subsection_end
    """
    try:
        gs_start, gs_end = find_top_level_section(lines, "general_settings")
    except ApplyError:
        gs_start = len(lines)
        if gs_start > 0 and lines[-1] != "":
            lines.append("")
            gs_start += 1
        lines.append("general_settings:")
        gs_end = len(lines)
    subsection_line = f"  {subsection}:"
    subsection_start: Optional[int] = None
    for index in range(gs_start + 1, gs_end):
        if lines[index] == subsection_line:
            subsection_start = index
            break

    if subsection_start is None:
        subsection_start = gs_end
        lines.insert(subsection_start, subsection_line)
        gs_end += 1

    subsection_end = gs_end
    for index in range(subsection_start + 1, gs_end):
        line = lines[index]
        if line and not line.startswith((" ", "#")):
            subsection_end = index
            break
        if line.startswith("  ") and not line.startswith("    "):
            subsection_end = index
            break

    return gs_start, gs_end, subsection_start, subsection_end


def ensure_validation_pass_through_endpoints(
    config_file: Path,
    check: bool,
    mock_backend_url: str,
) -> bool:
    text = read_text(config_file)
    lines = text.splitlines()
    mock_base = _normalize_mock_backend_url(mock_backend_url)
    mock_v1_base = f"{mock_base}/v1"

    _, _, _, subsection_end = _find_general_settings_subsection(
        lines, "pass_through_endpoints"
    )

    endpoint_blocks: List[Tuple[str, List[str]]] = [
        (
            '/pt/static/v1/chat/completions',
            [
                '    - path: "/pt/static/v1/chat/completions"',
                f'      target: "{mock_v1_base}/chat/completions"',
                "      headers:",
                '        Authorization: "Bearer backend-key-static"',
                '        content-type: "application/json"',
                '        accept: "application/json"',
                "      methods:",
                '        - "POST"',
            ],
        ),
        (
            '/pt/dynamic/v1/chat/completions',
            [
                '    - path: "/pt/dynamic/v1/chat/completions"',
                '      target: "custom_secret_manager.pass_through_openai_adapter"',
                "      methods:",
                '        - "POST"',
            ],
        ),
        (
            '/pt/prefix',
            [
                '    - path: "/pt/prefix"',
                f'      target: "{mock_v1_base}"',
                "      include_subpath: true",
                "      headers:",
                '        Authorization: "Bearer backend-key-prefix"',
                '        content-type: "application/json"',
                '        accept: "application/json"',
            ],
        ),
        (
            '/pt/prefix-headers',
            [
                '    - path: "/pt/prefix-headers"',
                f'      target: "{mock_v1_base}"',
                "      include_subpath: true",
                "      forward_headers: true",
                "      headers:",
                '        authorization: "Bearer backend-key-prefix-headers"',
                '        content-type: "application/json"',
                '        accept: "application/json"',
                '        x-route-fixed: "prefix-headers-enabled"',
                "      methods:",
                '        - "POST"',
            ],
        ),
    ]

    changed = False
    for path_marker, block in endpoint_blocks:
        path_line = f'    - path: "{path_marker}"'
        if path_line in lines:
            continue
        lines[subsection_end:subsection_end] = block + [""]
        subsection_end += len(block) + 1
        changed = True

    if not changed:
        return False
    return write_if_changed(config_file, "\n".join(lines) + "\n", check)


def ensure_validation_environment_variables(
    config_file: Path,
    check: bool,
    mock_backend_url: str,
) -> bool:
    text = read_text(config_file)
    lines = text.splitlines()
    mock_v1_base = f"{_normalize_mock_backend_url(mock_backend_url)}/v1"
    required_env: Dict[str, str] = {
        "OPENAI_MOCK_API_BASE": mock_v1_base,
        "OPENAI_MOCK_DEFAULT_API_KEY": "validation-dummy-key",
    }

    try:
        env_start, env_end = find_top_level_section(lines, "environment_variables")
    except ApplyError:
        env_start = len(lines)
        if env_start > 0 and lines[-1] != "":
            lines.append("")
            env_start += 1
        lines.append("environment_variables:")
        env_end = len(lines)

    key_to_index: Dict[str, int] = {}
    for index in range(env_start + 1, env_end):
        line = lines[index]
        if not line.startswith("  ") or line.startswith("    "):
            continue
        stripped = line.strip()
        if ":" not in stripped:
            continue
        key = stripped.split(":", 1)[0]
        key_to_index[key] = index

    changed = False
    insert_at = env_end
    for key, value in required_env.items():
        formatted = f'  {key}: "{value}"'
        if key in key_to_index:
            idx = key_to_index[key]
            if lines[idx] != formatted:
                lines[idx] = formatted
                changed = True
        else:
            lines.insert(insert_at, formatted)
            insert_at += 1
            changed = True

    if not changed:
        return False
    return write_if_changed(config_file, "\n".join(lines) + "\n", check)


def ensure_validation_profile(
    config_file: Path,
    check: bool,
    mock_backend_url: str,
) -> Iterable[Tuple[str, bool]]:
    yield "patch validation model_list", ensure_validation_model(
        config_file=config_file,
        check=check,
        mock_backend_url=mock_backend_url,
    )
    yield "patch validation pass_through_endpoints", ensure_validation_pass_through_endpoints(
        config_file=config_file,
        check=check,
        mock_backend_url=mock_backend_url,
    )
    yield "patch validation environment_variables", ensure_validation_environment_variables(
        config_file=config_file,
        check=check,
        mock_backend_url=mock_backend_url,
    )


def copy_hook(guidance_root: Path, check: bool) -> bool:
    if not SOURCE_HOOK.exists():
        raise ApplyError(f"Source hook not found: {SOURCE_HOOK}")

    target = guidance_root / "custom_secret_manager.py"
    source_text = SOURCE_HOOK.read_text(encoding="utf-8")
    if target.exists() and target.read_text(encoding="utf-8") == source_text:
        return False
    if not check:
        shutil.copyfile(SOURCE_HOOK, target)
    return True


def apply(
    guidance_root: Path,
    check: bool,
    enable_validation_profile: bool,
    mock_backend_url: Optional[str],
) -> Iterable[Tuple[str, bool]]:
    yield "copy custom_secret_manager.py", copy_hook(guidance_root, check)
    yield "patch Dockerfile", ensure_lines_after_from(guidance_root / "Dockerfile", check)
    yield "patch config/default-config-base.yaml", ensure_litellm_callback(
        guidance_root / "config" / "default-config-base.yaml", check
    )
    yield "patch ECS task role IAM", ensure_iam_provider_secret_access(
        guidance_root / "litellm-terraform-stack" / "modules" / "ecs" / "iam.tf",
        check,
    )
    if enable_validation_profile:
        if mock_backend_url is None:
            raise ApplyError(
                "--mock-backend-url is required when --enable-validation-profile is set."
            )
        yield from ensure_validation_profile(
            config_file=guidance_root / "config" / "default-config-base.yaml",
            check=check,
            mock_backend_url=mock_backend_url,
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply the local LiteLLM Secret Manager hook to an AWS Guidance checkout."
    )
    parser.add_argument(
        "--guidance-root",
        required=True,
        type=Path,
        help="Path to guidance-for-multi-provider-generative-ai-gateway-on-aws checkout.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Report pending changes without writing files.",
    )
    parser.add_argument(
        "--enable-validation-profile",
        action="store_true",
        help=(
            "Also patch Guidance config for AWS validation profile "
            "(openai.mock model + pass_through_endpoints + required env vars)."
        ),
    )
    parser.add_argument(
        "--mock-backend-url",
        type=str,
        help=(
            "Base URL for validation mock backend (Hono on Lambda behind API Gateway), "
            "for example: https://<api-id>.execute-api.<region>.amazonaws.com/prod"
        ),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    guidance_root = args.guidance_root.resolve()

    try:
        results = list(
            apply(
                guidance_root=guidance_root,
                check=args.check,
                enable_validation_profile=args.enable_validation_profile,
                mock_backend_url=args.mock_backend_url,
            )
        )
    except ApplyError as exc:
        print(f"ERROR: {exc}")
        return 1

    for label, changed in results:
        status = "would change" if args.check and changed else "changed" if changed else "ok"
        print(f"{status}: {label}")

    if args.check and any(changed for _, changed in results):
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
