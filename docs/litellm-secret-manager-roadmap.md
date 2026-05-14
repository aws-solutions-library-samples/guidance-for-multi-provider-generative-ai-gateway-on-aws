# LiteLLM Secret Manager roadmap

## Local phase

- LiteLLM runs through `lecs` with Redis, PostgreSQL, and the local config mount.
- `config/custom_secret_manager.py` is enabled by `litellm_settings.callbacks`.
- `openai.mock-gpt-4o-mini` points to the Hono mock backend on port `4010`.
- Local provider keys are supplied by `LITELLM_SECRET_MAP_JSON`:
  - `secret-openai-a` -> `backend-key-a`
  - `secret-openai-b` -> `backend-key-b`
- Local validation status (2026-05-14 UTC):
  - Static and dynamic header swap checks passed.
  - `include_subpath` checks passed.
  - `forward_headers` + fixed/optional header forwarding checks passed.
  - Missing/invalid secret checks fail before provider backend call.

## AWS phase

- Base deployment is the AWS Solutions Library Guidance for Multi-Provider
  Generative AI Gateway on AWS.
- Initial platform is ECS/Fargate because it matches this repository's local
  ECS task model.
- Apply `aws-guidance-overlay/apply.py` to the Guidance checkout before running
  the Guidance deployment scripts.
- For AWS validation-equivalent runs, apply with:
  - `--enable-validation-profile`
  - `--mock-backend-url <api-gateway-base-url-for-hono-lambda>`
- Validation mock backend for AWS is Hono on Lambda, exposed via API Gateway.
- Store provider credentials in AWS Secrets Manager under
  `litellm/provider/<provider>/<credential_alias>`.
- Store each secret as JSON containing `provider_api_key`.
- Create LiteLLM virtual keys with `metadata.secret_id` pointing at the provider
  secret name.
- ECS task role reads only `litellm/provider/*` provider secrets, plus the
  Guidance-managed LiteLLM and database secrets.
- Validation profile adds these to Guidance config automatically:
  - `openai.mock-gpt-4o-mini` model entry
  - pass-through routes (`/pt/static`, `/pt/dynamic`, `/pt/prefix`, `/pt/prefix-headers`)
  - required `OPENAI_MOCK_*` environment variables

## Success criteria

- Local: mock backend receives the provider key from `LITELLM_SECRET_MAP_JSON`,
  not the LiteLLM virtual key.
- AWS: OpenAI-compatible and pass-through validation routes behave equivalent to
  local checks when routed to the Hono-on-Lambda endpoint.
- Bedrock model calls are not modified by the hook.
- Missing or unreadable provider secrets fail before the provider backend is
  called.
