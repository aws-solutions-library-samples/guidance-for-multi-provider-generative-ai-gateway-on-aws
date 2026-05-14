# AWS validation runbook (ECS/Fargate)

## Goal

Run AWS-side validation equivalent to local pass-through and secret resolution checks, using a Hono mock backend running on AWS Lambda (via API Gateway).

## Scope and assumptions

- Target platform: ECS/Fargate (Guidance stack).
- Secret source for provider key resolution: AWS Secrets Manager.
- No `LITELLM_SECRET_MAP_JSON` on AWS.
- Bedrock remains in-scope for non-regression checks.
- OpenAI-compatible checks use a Hono-on-Lambda endpoint exposed by API Gateway.

## Prerequisites

- Guidance repository checkout is available.
- AWS account/region are selected and credentials are configured.
- Hono mock backend is deployed on AWS Lambda.
- API Gateway endpoint for the Lambda function is deployed and reachable from LiteLLM networking.
- Base URL example: `https://<api-id>.execute-api.<region>.amazonaws.com/prod`

## 1. Apply overlay with validation profile

```bash
python3 /path/to/test-litellm-on-aws/aws-guidance-overlay/apply.py \
  --guidance-root ./guidance-for-multi-provider-generative-ai-gateway-on-aws \
  --enable-validation-profile \
  --mock-backend-url https://<api-id>.execute-api.<region>.amazonaws.com/prod
```

Expected patch outcomes:

- Hook copied and callback enabled.
- IAM permission for `litellm/provider/*` secret reads.
- Validation model and pass-through endpoints injected.
- `OPENAI_MOCK_API_BASE` and `OPENAI_MOCK_DEFAULT_API_KEY` injected.

## 2. Deploy Guidance stack

Run the Guidance deployment flow for ECS/Fargate in your environment.

Capture for evidence:

- LiteLLM service endpoint
- Master key and auth path used for `/key/generate`
- ECS task role ARN

## 3. Prepare AWS Secrets Manager test secrets

Create these secrets (JSON values):

- `litellm/provider/openai/team-a` => `{"provider_api_key":"backend-key-a"}`
- `litellm/provider/openai/team-b` => `{"provider_api_key":"backend-key-b"}`
- `litellm/provider/openai/invalid-format` => `123` (or non-string/non-object shape)

## 4. Generate LiteLLM virtual keys

Generate validation keys with metadata:

- key A: `metadata.secret_id=litellm/provider/openai/team-a`
- key B: `metadata.secret_id=litellm/provider/openai/team-b`
- key invalid: `metadata.secret_id=litellm/provider/openai/invalid-format`
- key missing-metadata: metadata without `secret_id`

## 5. Execute validation cases

### Case group A: OpenAI-compatible route (`/v1/chat/completions`)

- A1 success: key A, `model=openai.mock-gpt-4o-mini` => backend receives `Authorization: Bearer backend-key-a`.
- A2 success: key B, same model => backend receives `Authorization: Bearer backend-key-b`.
- A3 regression guard: Bedrock model call does not trigger provider-key swap logic.

### Case group B: pass-through routes

- B1 static: `POST /pt/static/v1/chat/completions` => backend auth is fixed static value.
- B2 dynamic: `POST /pt/dynamic/v1/chat/completions` + `metadata.secret_id` => backend auth resolves per secret.
- B3 include_subpath: `POST /pt/prefix/echo/sub/path?client=1` => backend path/query preserved.
- B4 include_subpath + headers: `POST /pt/prefix-headers/echo/sub/path?client=1` with `X-Client-Trace` => backend receives fixed `authorization`, fixed route header, and forwarded client header.

### Case group C: failure modes

- C1 missing secret_id on strict path => HTTP 403 and backend not called.
- C2 unreadable/missing secret => HTTP 403 and backend not called.
- C3 invalid secret format => HTTP 403 and backend not called.

## 6. Evidence collection

For each case, capture:

- Request payload and request headers used.
- LiteLLM response status/body.
- Hono (Lambda) inspect response (`method`, `path`, `query`, `headers.authorization`).
- LiteLLM logs for hook decision and secret-read failures.

## Exit criteria

- All success cases in groups A/B match local behavior expectations.
- All failure cases in group C fail before provider backend invocation.
- Bedrock path remains unaffected by provider-key swap logic.
