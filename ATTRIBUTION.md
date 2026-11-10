# Attribution

This Guidance uses the following open source software. None of it is included in this repository: each component
is pulled unmodified from its upstream source at deployment, build or test time.

## Gateway

| Component | Used for | License |
| --- | --- | --- |
| [LiteLLM](https://github.com/BerriAI/litellm) (`ghcr.io/berriai/litellm` container image) | The gateway itself | [MIT License](https://github.com/BerriAI/litellm/blob/main/LICENSE), except the `enterprise/` directory, which is under a separate licence (`enterprise/LICENSE`) |
| [Terraform AWS provider](https://github.com/hashicorp/terraform-provider-aws) | Deployment | [Mozilla Public License 2.0](https://github.com/hashicorp/terraform-provider-aws/blob/main/LICENSE) |
| [Terraform random provider](https://github.com/hashicorp/terraform-provider-random) | Generated secrets | [Mozilla Public License 2.0](https://github.com/hashicorp/terraform-provider-random/blob/main/LICENSE) |

## Amazon Bedrock AgentCore example

| Component | Used for | License |
| --- | --- | --- |
| [Strands Agents](https://github.com/strands-agents/harness-sdk) (`strands-agents`) | Agent framework | [Apache License 2.0](https://github.com/strands-agents/harness-sdk/blob/main/LICENSE.APACHE) |
| [Amazon Bedrock AgentCore SDK](https://github.com/aws/bedrock-agentcore-sdk-python) (`bedrock-agentcore`) | AgentCore Runtime and Identity integration | [Apache License 2.0](https://github.com/aws/bedrock-agentcore-sdk-python/blob/main/LICENSE.txt) |
| [OpenAI Python library](https://github.com/openai/openai-python) (`openai`) | OpenAI-compatible client for the gateway | [Apache License 2.0](https://github.com/openai/openai-python/blob/main/LICENSE) |
| [Boto3](https://github.com/boto/boto3) | AWS API calls in `scripts/invoke.py` of the AgentCore example | [Apache License 2.0](https://github.com/boto/boto3/blob/develop/LICENSE) |

## Load test

| Component | Used for | License |
| --- | --- | --- |
| [Locust](https://github.com/locustio/locust) | Load generation | [MIT License](https://github.com/locustio/locust/blob/master/LICENSE) |
| [aiohttp](https://github.com/aio-libs/aiohttp) | Stand-in model provider | [Apache License 2.0](https://github.com/aio-libs/aiohttp/blob/master/LICENSE.txt) |

## Development and test tooling

| Component | Used for | License |
| --- | --- | --- |
| [pytest](https://github.com/pytest-dev/pytest) | Python tests | [MIT License](https://github.com/pytest-dev/pytest/blob/main/LICENSE) |
| [pytest-aiohttp](https://github.com/aio-libs/pytest-aiohttp) | Load-test tests | [Apache License 2.0](https://github.com/aio-libs/pytest-aiohttp/blob/master/LICENSE) |
| [Ruff](https://github.com/astral-sh/ruff) | Python linting and formatting | [MIT License](https://github.com/astral-sh/ruff/blob/main/LICENSE) |
