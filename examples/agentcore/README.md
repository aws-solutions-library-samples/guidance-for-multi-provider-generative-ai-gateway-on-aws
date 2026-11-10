# Agents on Amazon Bedrock AgentCore Runtime through the gateway

This example deploys a [Strands](https://strandsagents.com/) agent on
[Amazon Bedrock AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agents-tools-runtime.html)
that does **all** of its LLM inference through the LiteLLM gateway. The agent is
a gateway client like any other: its own virtual key decides which models it may
use, its budget and rate limits are enforced by the gateway, and every model
call shows up in the gateway's spend logs under that key.

It consumes the gateway as plain inputs (URL, VPC, subnets, master key secret
ARN) and does not modify the gateway's stacks.

```text
 caller (SigV4)                         AWS account
 ─────────────►  AgentCore Runtime (VPC mode, gateway's private subnets)
                 ┌───────────────────────────────────────┐
                 │ Strands agent (main.py)               │
                 │   OpenAI-compatible model provider ───┼──► LiteLLM gateway /v1 ──► Amazon Bedrock
                 │   key from AgentCore Identity ◄───┐   │     (virtual key: model list,   and other
                 └───────────────────────────────────┼───┘      budget, rate limits, logs)  providers
                                                     │
                      API-key credential provider ───┘──► Secrets Manager secret (the virtual key)
```

## How it works

- **Inference.** The agent uses Strands' `OpenAIModel` with `base_url` set to
  `<gateway_url>/v1` and the model name registered in the gateway. LiteLLM's
  OpenAI-compatible API supports streaming and tool calls, so no request
  rewriting or SDK patching is involved.
- **No direct model access.** The runtime's execution role has no Amazon Bedrock
  permissions, so the agent reaches models through the gateway.
- **The key.** Each agent gets its own LiteLLM virtual key (alias = the agent
  name), limited to the agent's model, with its own budget and rate limits.
  `scripts/agent-key.sh` creates it through the gateway's API with the master
  key and writes it into a Secrets Manager secret. An AgentCore Identity
  API-key credential provider points at that secret; the agent obtains the key
  per request by exchanging the workload access token AgentCore Runtime issues
  for the invocation. The key is not in environment variables, the code bundle,
  Terraform variables or Terraform state, and the runtime does not receive the
  master key. With a LiteLLM licence, agents can use identity provider access
  tokens instead; see
  [JWT authentication instead of a virtual key](#jwt-authentication-instead-of-a-virtual-key).
- **Network.** The runtime runs in the gateway's VPC (VPC network mode), so it
  reaches a private, internal gateway. Its security group allows the gateway
  port towards the gateway's CIDR and HTTPS towards AWS APIs (through the VPC's
  NAT gateway or VPC endpoints). A private gateway admits its VPC CIDR by
  default, so no change to the gateway is needed. If the gateway sets
  `client_cidrs`, the VPC CIDR is no longer admitted: add this example's
  security group (`security_group_id` output) to the gateway's
  `client_security_group_ids` and redeploy the gateway.
- **Private certificate authority.** If the gateway's certificate comes from a
  private CA, set `gateway_ca_certificate_file` to the CA certificate (PEM).
  The agent trusts it in addition to the public roots for its gateway calls
  (it reaches the runtime base64-encoded in the `GATEWAY_CA_PEM_BASE64`
  environment variable; a CA certificate is not secret), and `scripts/agent-key.sh` passes it to curl.
- **Deployment.** Direct code deployment: `scripts/build.sh` builds a zip of
  the agent and its dependencies for the runtime's platform (Linux arm64,
  Python 3.13); Terraform uploads it to S3 and creates the runtime from it. No
  container build is needed. Agent code, configuration and other content that
  you create and upload are "Your Content" as defined in the
  [AWS Customer Agreement](https://aws.amazon.com/agreement/). AWS does not
  claim ownership of it.

## Prerequisites

- A deployed gateway with a model registered in it (`model_id` below).
- A machine that reaches the gateway (inside its network, or connected to its
  VPN) with Terraform >= 1.11, the AWS CLI v2, `python3` with `pip`, `zip`,
  `curl` and `jq`; `boto3` for `scripts/invoke.py`. The scripts take the region
  from `AWS_REGION`.
- AWS credentials for the gateway's account that may create the resources
  below, read the gateway's master key secret, and invoke AgentCore runtimes.
- AgentCore Runtime available in the gateway's region, and the subnets in
  [Availability Zones it supports](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-vpc.html).
  The first VPC-mode runtime in an account creates AgentCore's network
  service-linked role.
- The Terraform state bucket of the gateway deployment
  (`litellm-gateway-tfstate-<account>-<region>`, or set `TF_STATE_BUCKET`). The
  example's state is stored under its own key,
  `examples/agentcore/<name>.tfstate`.

## Deploy

```bash
cd examples/agentcore
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Fill in the gateway values from:
#   terraform -chdir=<gateway>/terraform/foundation output
#   terraform -chdir=<gateway>/terraform/app output
export AWS_REGION=<gateway region>
scripts/deploy.sh            # shows the plan and asks for confirmation
```

The gateway outputs are described in the gateway's
[configuration reference](../../docs/configuration.md#outputs); the foundation
outputs are also saved in
`deploy/.generated/<deployment_name>-foundation-outputs.tfvars.json`.

`deploy.sh` builds the bundle and runs `terraform apply`. During the apply,
Terraform runs `scripts/agent-key.sh create`, which creates the agent's
virtual key in LiteLLM (only if the agent has no working key) and stores it.
Rerunning `deploy.sh` updates the agent; an unchanged agent is a no-op.

Resources created (all named after `name`, default `llmgw-agent-demo`):

| Resource | Name |
| --- | --- |
| AgentCore runtime (and its default endpoint and workload identity) | `llmgw_agent_demo` (runtime names allow no hyphens) |
| AgentCore Identity API-key credential provider | `llmgw-agent-demo-gateway` |
| Secrets Manager secret with the virtual key | `llmgw-agent-demo-gateway-key` |
| IAM execution role and inline policy | `llmgw-agent-demo-runtime` |
| Security group and two egress rules | `llmgw-agent-demo-runtime` |
| S3 bucket for code bundles | `llmgw-agent-demo-code-<account>-<region>` |
| LiteLLM virtual key (in the gateway) | alias `llmgw-agent-demo` |

## Invoke

```bash
python3 scripts/invoke.py "How many words are in 'the quick brown fox'? Use your tool."
```

```json
{
  "result": "\"the quick brown fox\" has **4** words.",
  "model": "claude-opus-5-5",
  "usage": { "inputTokens": 919, "outputTokens": ..., "totalTokens": ..., ... }
}
```

The region is `--region`, else `AWS_REGION`, else `AWS_DEFAULT_REGION`, else
the region in the runtime ARN. Callers need `bedrock-agentcore:InvokeAgentRuntime` and
`bedrock-agentcore:InvokeAgentRuntimeForUser` on the runtime. A SigV4 caller
must pass a runtime user ID (`runtimeUserId`; `invoke.py --user-id`, default
`example-user`): AgentCore
Runtime issues the invocation's workload access token for it, and without that
token the agent cannot obtain its gateway key (it answers with an error).

When the gateway refuses a request, the agent returns the gateway's verdict,
for example after the key's budget is spent:

```json
{ "error": "The gateway rejected the request (HTTP 422): ... Budget has been exceeded! Key=llmgw-agent-demo ..." }
```

## Verify in the gateway

Each agent invocation appears in the LiteLLM admin UI under **Logs** as one
request per model call, filtered by the key alias; their tokens add up to the
`usage` the agent reports. **Virtual Keys** shows the key's limits and spend.
`scripts/agent-key.sh status` prints the same limits and spend from the command
line. LiteLLM writes spend in batches, so allow about a minute after an
invocation.

## Operate

- **Rotate the key:** `scripts/agent-key.sh rotate` revokes the key and stores a
  new one. The agent picks it up on the next request; no redeploy. A new key
  starts with zero spend (the old key's requests remain in the spend logs).
- **Change limits or the model:** edit `key_*` or `model_id` in
  `terraform.tfvars` and rerun `deploy.sh`. A changed key setting replaces
  (rotates) the key.
- **Status:** `scripts/agent-key.sh status`.
- **Logs:** CloudWatch log group `/aws/bedrock-agentcore/runtimes/<runtime id>-DEFAULT`.

## Teardown

```bash
cd examples/agentcore
AWS_REGION=<gateway region> scripts/teardown.sh
```

Terraform revokes the agent's virtual key in LiteLLM (so run it where the
gateway is reachable) and then deletes every resource of the example; the
gateway is not touched. If the gateway is already gone,
`scripts/teardown.sh --skip-key-revocation` destroys the AWS resources only.
The runtime's CloudWatch log group is created by AgentCore, not by Terraform,
and remains; delete it with
`aws logs delete-log-group --log-group-name /aws/bedrock-agentcore/runtimes/<runtime id>-DEFAULT`
if it is not needed.

## Tests

Offline, no AWS access:

```bash
# Agent (configuration, full invocations against a local stand-in for the
# gateway) and scripts/invoke.py (region resolution, the client call)
python3 -m venv .venv && .venv/bin/pip install -r agent/requirements-dev.txt
.venv/bin/python -m pytest agent/tests scripts/tests
for d in agent scripts; do (cd $d && ../.venv/bin/ruff check . && ../.venv/bin/ruff format --check .); done

# Terraform: plans against a mocked AWS provider
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform test
```

## JWT authentication instead of a virtual key

This example authenticates the agent with a LiteLLM virtual key. With a
LiteLLM licence, the gateway also accepts access tokens (JWTs) issued by your
identity provider, so the agent holds no gateway key at all. At a high level:

1. Enable JWT authentication on the gateway, as described in
   [JWT authentication for applications](../../docs/deployment.md#jwt-authentication-for-applications).
2. At the identity provider, register a client for the agent that obtains
   access tokens with the OAuth 2.0 client-credentials grant and a scope for
   the gateway.
3. In the gateway, create a LiteLLM team for that client (its team ID is the
   value of the token claim the gateway maps to teams), with the agent's model,
   budget and rate limits. The team takes the place of the agent's virtual key.
4. In AgentCore Identity, create an OAuth2 credential provider for your
   identity provider with that client's ID and secret, in place of the API-key
   credential provider.
5. In the agent, obtain the access token from AgentCore Identity
   (`requires_access_token` with the machine-to-machine flow and the gateway
   scope) instead of the API key (`requires_api_key`), and pass it to the
   OpenAI client as its API key. Tokens expire, so obtain one per request, as
   the example does with the key.

The model call, spend tracking and limits work as with a virtual key; spend is
recorded on the team.

## Design notes

- **Why the OpenAI-compatible API.** Other ways to reach the gateway from
  Strands work too: `BedrockModel` with a boto3 session redirected to LiteLLM's
  `/bedrock` pass-through route (requires unsigned requests, an injected
  `Authorization` header and endpoint rewriting), or Strands' `LiteLLMModel`
  (pulls the full LiteLLM SDK into the bundle). The OpenAI-compatible provider
  needs only a base URL and a key, and is LiteLLM's primary API.
- **Why AgentCore Identity for the key.** Runtime environment variables are
  visible to anyone who can describe the runtime. The credential provider keeps
  the key in a secret that the runtime role is granted read access to, behind a
  per-request workload access token. The secret is created and owned by this example
  (`EXTERNAL` secret source), so the key is kept out of Terraform state, and can
  be rotated without redeploying.
- **Fronting the agent with LiteLLM (Agents).** This example governs the
  agent's outbound model calls. To also govern who may call the agent, consider
  LiteLLM's agent registry: it has a `bedrock_agentcore` agent type (model
  `bedrock/agentcore/<runtime ARN>`) for exposing AgentCore agents through the
  gateway (A2A at `/a2a/<agent id>`) with per-agent rate limits, access groups
  and spend tracking. It requires granting the gateway's task role
  `bedrock-agentcore:InvokeAgentRuntime` on the runtime, which the gateway
  stack does not do by default. See the
  [LiteLLM agents documentation](https://docs.litellm.ai/) for setup.
- **Gateways without internet access.** In a VPC without a NAT gateway the
  runtime needs VPC endpoints for everything it calls: S3 (gateway endpoint, for
  the code bundle), CloudWatch Logs, and AgentCore (`bedrock-agentcore`, for
  AgentCore Identity). Without a NAT gateway, add these endpoints.
- **TLS.** Use an HTTPS gateway URL outside of trials; the agent then verifies
  the gateway's certificate with the default trust store.
