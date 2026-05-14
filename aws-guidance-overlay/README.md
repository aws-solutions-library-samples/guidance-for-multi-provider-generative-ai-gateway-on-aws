# AWS Guidance overlay for LiteLLM provider secrets

This overlay applies the local `config/custom_secret_manager.py` hook to
`aws-solutions-library-samples/guidance-for-multi-provider-generative-ai-gateway-on-aws`.

The AWS target is ECS/Fargate first. EKS can reuse the same hook, but this
overlay intentionally patches only the ECS task role and image path.

## What it changes

- Copies `custom_secret_manager.py` into the Guidance Docker build context.
- Updates the Guidance LiteLLM image to install `boto3`, copy the hook into
  `/app/custom_secret_manager.py`, and include `/app` in `PYTHONPATH`.
- Adds `custom_secret_manager.proxy_handler_instance` to
  `config/default-config-base.yaml`.
- Adds ECS task-role permission to read provider secrets under
  `litellm/provider/*`.

## Apply to a Guidance checkout

```bash
git clone https://github.com/aws-solutions-library-samples/guidance-for-multi-provider-generative-ai-gateway-on-aws.git
python3 /path/to/test-litellm-on-aws/aws-guidance-overlay/apply.py \
  --guidance-root ./guidance-for-multi-provider-generative-ai-gateway-on-aws
```

Dry run:

```bash
python3 /path/to/test-litellm-on-aws/aws-guidance-overlay/apply.py \
  --guidance-root ./guidance-for-multi-provider-generative-ai-gateway-on-aws \
  --check
```

## Validation profile mode

If you want to run AWS validation cases equivalent to local `pass_through_endpoints`
checks, enable the validation profile.

```bash
python3 /path/to/test-litellm-on-aws/aws-guidance-overlay/apply.py \
  --guidance-root ./guidance-for-multi-provider-generative-ai-gateway-on-aws \
  --enable-validation-profile \
  --mock-backend-url https://<api-id>.execute-api.<region>.amazonaws.com/prod
```

This mode additionally patches `config/default-config-base.yaml` with:

- `model_list` entry: `openai.mock-gpt-4o-mini`
- `general_settings.pass_through_endpoints` entries for:
  - `/pt/static/v1/chat/completions`
  - `/pt/dynamic/v1/chat/completions`
  - `/pt/prefix`
  - `/pt/prefix-headers` (`forward_headers: true`)
- `environment_variables`:
  - `OPENAI_MOCK_API_BASE`
  - `OPENAI_MOCK_DEFAULT_API_KEY`

## AWS secret contract

Create one Secrets Manager secret per provider credential.

Secret name:

```text
litellm/provider/<provider>/<credential_alias>
```

Example:

```text
litellm/provider/openai/team-a
```

Secret value:

```json
{"provider_api_key":"real-provider-key"}
```

Generate a LiteLLM key with the secret id in metadata:

```bash
curl -s -X POST "$LITELLM_BASE_URL/key/generate" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias":"team-a-openai",
    "models":["gpt-4o-mini"],
    "metadata":{"secret_id":"litellm/provider/openai/team-a"}
  }'
```

For AWS deployments, do not set `LITELLM_SECRET_MAP_JSON`; that variable is only
for local verification.
