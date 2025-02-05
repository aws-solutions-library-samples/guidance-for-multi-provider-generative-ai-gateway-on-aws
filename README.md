# AWS GenAI Gateway

Project ACTIVE as of Dec 20, 2024

## Project Overview

This project provides a simple CDK deployment of LiteLLM into ECS on AWS. It aims to be pre-configured with defaults that will allow most users to quickly get started with LiteLLM.

It also provides additional features on top of LiteLLM such as an AWS Bedrock Interface (instead of the default OpenAI interface), support for AWS Bedrock Managed Prompts, Chat History, and support for Okta Oauth 2.0 JWT Token Auth.

## Architecture

![Architecture Diagram](./media/Genai-Gateway-Architecture.png)

## How to deploy

### Prerequisites

1. Docker
2. AWS CLI
3. CDK
4. yq (install with brew if on Mac, download binaries if on Linux (see `Installing yq` below))
5. Make sure you have already run `cdk bootstrap` against the account and region you are deploying to.

If you have `DEPLOYMENT_PLATFORM` set to `EKS`:

6. kubectl
7. Terraform (needed because of limitations in the EKS CDK constructs. We hope to eventually unify the deployment in one IAC solution.)

### Installing kubectl

On Mac
```
brew install kubectl
```

On Linux

ToDo


### Installing yq

On Mac
```
brew install yq
```

On Linux
```
# Download the binary
VERSION="v4.40.5"  # Replace with desired version
BINARY="yq_linux_amd64"
sudo wget https://github.com/mikefarah/yq/releases/download/${VERSION}/${BINARY} -O /usr/bin/yq
# Make it executable
sudo chmod +x /usr/bin/yq
```

### Environment tested and confirmed

```
Docker: version 27.3.1
AWS CLI: version 2.19.5
CDK: 2.170.0
yq: version 4.40.5
Terraform: v1.5.7
kubectl Client Version: v1.32.1
kubectl Kustomize Version: v5.5.0
```

### Deploying from AWS Cloud9 (Optional) (Not tested with EKS)

If it's easier for you, you can deploy from an AWS Cloud9 environment using the following steps:

1. Go to Cloud9 in the console
2. Click `Create environment`
3. Change `Instance Type` to `t3.small` (need to upgrade from micro for Docker to run effectively)
4. Leave rest as default, and click `Create`
5. Once, the environment is deployed, click `Open` under `Cloud9 IDE`
6. In the terminal, run the following commands:
7. `git clone https://github.com/aws-samples/genai-gateway.git`
8. run `sudo ./install-cloud9-prerequisites.sh` (This will install `jq` for you and update you to the latest version of `cdk`. All other dependencies are pre-installed on Cloud9)
9. Run the `Deployment Steps` described below

### Creating your certificate

#### Domain and Certifcate, AWS Internal

1. Reach out to mirodrr for instructions on this

#### Domain and Certificate, AWS Customer

1. Follow the instructions [here](https://docs.aws.amazon.com/acm/latest/userguide/gs-acm-request-public.html) to create a certificate with AWS Certificate Manager.

2. Follow the instructions [here](https://docs.aws.amazon.com/acm/latest/userguide/domain-ownership-validation.html) to validate your domain ownership for your certificate.


#### Deployment Steps

1. Run `cp .env.template .env`
2. In `.env`, set the `CERTIFICATE_ARN` to the ARN of the certificate you created in the `Creating your certificate` section of this README.
3. In `.env`, set the `DOMAIN_NAME` to the sub domain you created in the `Creating your certificate` section of this README.
4. If you'd like to provide an existing VPC, set `EXISTING_VPC_ID` to your existing VPC. The VPC is expected to have both private and public subnets. The public subnets should have Auto-assign public IPv4 address set to yes. The VPC should also have at least one NAT Gateway. This has been tested with the following VPC specification in CDK
```
const vpc = new ec2.Vpc(this, 'LiteLLMVpcPreExisting', { maxAzs: 2, natGateways: 1 });
```
5. If you'd like to use EKS instead of ECS, switch `DEPLOYMENT_PLATFORM="ECS"` to `DEPLOYMENT_PLATFORM="EKS"` (Still in beta, probably has bugs.) (Note: you currently cannot freely switch between these. You must delete your existing deployment to switch deployment platforms.) (Also, deleting the stack when using EKS mode will fail because of EKS CDK issues. You will need to do some manual cleanup and some delete retries. We will try to find a fix for this soon.)
6. In `.env`, Fill out any API Keys you need for any third party providers. If you only want to use Amazon Bedrock, you can just leave the `.env` file as-is
7. By default, this solution is deployed with redis caching enabled, and with most popular model providers enabled. If you want to remove support for certain models, or add more models, you can create and edit your own `config/config.yaml` file. If not, the deployment will automatically use the `config/default-config.yaml`. Make sure you [enable model access](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access-modify.html) on Amazon Bedrock.
8. Make sure you have valid AWS credentials configured in your environment before running the next step
9. Run `./deploy.sh`
10. After the deployment is done, you can visit the UI by going to the url at the stack output `LitellmCdkStack.ServiceURL`, which is the `DOMAIN_NAME` you configured earlier.
11. If you deployed to ECS, the master api key is stored in AWS Secrets Manager in the `LiteLLMSecret` secret. If you deployed to EKS, the master key will be in the stack output `LitellmCdkStack.MasterKey`. We will try to standardize this between the two modes soon. This api key can be used to call the LiteLLM API, and is also the default password for the LiteLLM UI.

#### Usage Instructions

Using LiteLLM is practically Identical to using OpenAI, you just need to replace the baseurl and the api key with your LiteLLM ones

```
import openai # openai v1.0.0+
client = openai.OpenAI(api_key="anything",base_url="https://<Your-Proxy-Endpoint>") # set proxy to base_url
response = client.chat.completions.create(model="anthropic.claude-3-5-sonnet-20240620-v1:0", messages = [
    {
        "role": "user",
        "content": "this is a test request, write a short poem"
    }
])

print(response)
```

#### Compare Models

If you would like to compare different models, you can use the `scripts/benchmark.py` script. To do so, do the following:

1. `cd scripts`
2. `python3 -m venv myenv`
3. `source myenv/bin/activate`
4. `pip3 install -r requirements.txt`
5. `cp .env.template .env`
6. Update the `.env` file with your litellm base url, and a valid litellm api key. Also change the list of model ids you would like to benchmark if needed.
7. `benchmark.py` has a list of questions to use for the benchmark, at the top of the file. You can edit this list to try out different questions.
8. run `python3 benchmark.py`
9. The script will output the response from each model for each question, as well as the response time and the cost

#### Config.yaml (all values pre-populated in Config.yaml, what they do, and what the default values are.)

`model_list`: within this field, many different models are already configured for you. If you would like to add more models, or remove models, edit this field. Some model providers (such as Databricks and Azure OpenAI) will need you to add additional configuration to function, so they are commented out by default.

`model_name`: this is the model's public name. You can set it to whatever you like. When someone is calling your model using the OpenAI client, they will use this value for the model id. By default, the `model_name` is set to the model id from each provider. 

If a model id is used by two different providers, we instead used `<provider>/<model_id>` as the `model_name`. For example, the `github` provider shares a model id with the `groq` provider. So, to avoid the conflict, we use `github/llama-3.1-8b-instant` instead of just `llama-3.1-8b-instant`


`litellm_params`: This is the full list of additional parameters sent to the model. For most models, this will only be `model` which is the model id used by the provider. Some providers such as `azure` need additional parameters, which are documented in `config/default-config.yaml`. 

You can also use this to set default parameters for the model such as `temperature` and `top_p`. 

You can also use this to override the default region for a model. For example, if you deploy the litellm to `us-east-1`, but want to use a AWS Bedrock model in `us-west-2`, you would set `aws_region_name` to `us-west-2`. The parameter to adjust the default region will vary by LLM Provider

You can also use this to set a `weight` for an LLM to load balance between two different models with the same `model_name`

`litellm_settings`: These are additional settings for the litellm proxy

`litellm_settings.cache`: Whether to enable or disable prompt caching. Caches prompt results to save time and money for repeated prompts. Set to `True` by default.

`litellm_settings.cache_params.type`: The type of cache to use. Set to `Redis` by default. Redis is currently the only cache type that will work out of the box with this deployment

`litellm_settings.max_budget`: (float) sets max budget in dollars across the entire proxy across all API keys. Note, the budget does not apply to the master key. That is the only exception. Set to an extremly large value by default (`1000000000.0`).

`litellm_settings.budget_duration`: (str) frequency of budget reset for entire proxy. - You can set duration as seconds ("30s"), minutes ("30m"), hours ("30h"), days ("30d"), months ("1mo"). Set to `1mo` (1 month) by default

`litellm_settings.max_internal_user_budget`: (float) sets default budget in dollars for each internal user. (Doesn't apply to Admins. Doesn't apply to Teams. Doesn't apply to master key). Set to an extremely large value by default (`1000000000.0`)

`litellm_settings.internal_user_budget_duration`: (str) frequency of budget reset for each internal user - You can set duration as seconds ("30s"), minutes ("30m"), hours ("30h"), days ("30d"), months ("1mo"). Set to `1mo` (1 month) by default

`litellm_settings.success_callback`: defines where success logs are sent to. Defaults to s3. s3 is the only destination that works out of the box with this deployment

`litellm_settings.failure_callback`: defines where failure logs are sent to. Defaults to s3. s3 is the only destination that works out of the box with this deployment

`litellm_settings.service_callback`: defines where service logs (such as rds and redis) are sent to. Defaults to s3. s3 is the only destination that works out of the box with this deployment

`litellm_settings.s3_callback_params.s3_bucket_name`: defines the bucket where the logs will be sent to. Is automatically populated with the name of an S3 bucket that is created during deployment

`litellm_settings.s3_callback_params.s3_region_name`: defines the bucket region where the logs will be sent to. Is automatically populated with the current region used during deployment

##### Routing

###### A/B testing and Load Balancing

To do A/B testing with two different models, do the following:
1. Define two different models with the same `model_name`
2. Point them each to one of the two different models you want to A/B test
3. Set the `weight` for each of them to determine the percentage of traffic you want going to each model

Example: Let's say you're using OpenAI, but you want to migrate to Anthropic Claude on AWS Bedrock. You want to send 10% of your traffic there to see if you're getting comparible speed and quality before you fully commit. You can do so like this in your `config.yaml`:

```
- model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      weight: 9
- model_name: gpt-4o
    litellm_params:
      model: bedrock/anthropic.claude-3-5-sonnet-20240620-v1:0 
      weight: 1
```

You can list several models under the same model name, and litellm will automatically distribute traffic between them, and if one begins failing, it will fall back to the others

Example:

```
model_list:
  - model_name: claude-3-5-sonnet-20240620-v1:0
    litellm_params:
      model: bedrock/anthropic.claude-3-5-sonnet-20240620-v1:0 
  - model_name: claude-3-5-sonnet-20240620-v1:0
    litellm_params:
      model: bedrock/anthropic.claude-3-haiku-20240307-v1:0
  - model_name: claude-3-5-sonnet-20240620-v1:0
    litellm_params:
      model: anthropic/claude-3-5-sonnet-20240620
```

To see more possible routing options, check the full documumentation: https://docs.litellm.ai/docs/routing

###### Routing Strategies

By default, the solution is configured with usage-based-routing. This will always route to the model with lowest TPM (Token Per Minute) usage for that minute for a given `model_name`

This routing will also respect `tpm` (tokens per minute) and `rpm` (requests per minute) limits, and will stop sending traffic to a model if it exceeds that limit.

Example of setting multiple models to be load balanced between with differnt `tpm` and `rpm` limits

```
model_list:
  - model_name: claude-3-5-sonnet-20240620-v1:0
    tpm: 100000
    rpm: 1000
    litellm_params:
      model: bedrock/anthropic.claude-3-5-sonnet-20240620-v1:0 
  - model_name: claude-3-5-sonnet-20240620-v1:0
    tpm: 200000
    rpm: 2000
    litellm_params:
      model: bedrock/anthropic.claude-3-haiku-20240307-v1:0
  - model_name: claude-3-5-sonnet-20240620-v1:0
    tpm: 300000
    rpm: 3000
    litellm_params:
      model: anthropic/claude-3-5-sonnet-20240620
```

The routing strategy is configured like:

```
router_settings:
  routing_strategy: usage-based-routing-v2
  enable_pre_call_check: true
```

You can explore alternative routing strategies here: https://docs.litellm.ai/docs/routing#advanced---routing-strategies-%EF%B8%8F

###### Fallbacks

You can also configure fallbacks for an entire `model_name`. If all models in a given `model_name` are failing, you can configure a final fallback.

Let's say you love Claude 3.5 sonnet, but occationally your users perform a query that overwhelms its context window size. You can configure a fallback for that scenario. All requests will go to Claude 3.5 Sonnet, but if they are too large, they will go to gemini which has a larger context window

```
router_settings:
    context_window_fallbacks: [{"anthropic.claude-3-5-sonnet-20240620-v1:0": ["gemini-1.5-pro"]}]
```

If a `model_name` fails for any other reason, you can configure a generic fallback

```
router_settings:
    fallbacks: [{"gpt-4o": ["anthropic.claude-3-5-sonnet-20240620-v1:0"]}]
```

And finally you can set a fallback for all `model_name` as a global fallback in case of unexpected failures:

```
router_settings:
  default_fallbacks: ["anthropic.claude-3-haiku-20240307-v1:0"]
```

More details here https://docs.litellm.ai/docs/routing and here https://docs.litellm.ai/docs/proxy/reliability

##### Guardrails

To set Guardrails for your llm calls, do the following

1. Create a Guardrail in AWS Bedrock
2. Get the Guardrail ID and guardrail version
3. Define the Guardrail like the example below in your `config.yaml`

```
guardrails:
   - guardrail_name: "bedrock-pre-guard"
     litellm_params:
       guardrail: bedrock
       mode: "during_call" # supported values: "pre_call", "post_call", "during_call"
       guardrailIdentifier: ff6ujrregl1q # your guardrail ID on bedrock
       guardrailVersion: "1"         # your guardrail version on bedrock
       default_on: true # enforces the guardrail serverside for all models. Caller does not need to pass in the name of the guardrail for it to be enforced.
```

If you set `default_on` to `true`, the guardrail will be enforced at all times. If you set it to false, enforcement is optional. 

In the case that `default_on` is `false`, in order to make use of the Guardrail, you must specifiy it's name in the client call. Example:

```
curl -X POST "https://<Your-Proxy-Endpoint>/user/new" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer <Your-Master-Key-Or-Admin-Key>" \
-d '{
    "model": "anthropic.claude-3-5-sonnet-20240620-v1:0",
    "messages": [
        {
            "role": "user",
            "content": "prohibited topic"
        }
    ],
    "guardrails": ["bedrock-pre-guard"]
}'
```

More details on guardrails here:
https://docs.litellm.ai/docs/proxy/guardrails/bedrock

#### Common Operations
See full documentation for all Operations here:
https://litellm-api.up.railway.app/#/Internal%20User%20management/new_user_user_new_post


#### Create new user

Use this to create a new INTERNAL user. Internal Users can access LiteLLM Admin UI to make keys. This creates a new user and generates a new api key for the new user. The new api key is returned.

If you don't specify a budget, the values in `litellm_settings.max_internal_user_budget` and `litellm_settings.internal_user_budget_duration` are applied to the user.

##### Create User with default budget defined in your config.yaml:
```
curl -X POST "https://<Your-Proxy-Endpoint>/user/new" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer <Your-Master-Key-Or-Admin-Key>" \
-d '{
     "user_email": "new_user@example.com",
     "user_role": "internal_user"
 }'
```

##### Create User with budget that overrides default (in this example we give a budget of 1000 dollars of spend a month)

```
curl -X POST "https://<Your-Proxy-Endpoint>/user/new" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer <Your-Master-Key-Or-Admin-Key>" \
-d '{
     "user_email": "new_user@example.com",
     "user_role": "internal_user"
     "max_budget": 1000.0,
     "budget_duration": "1mo"
 }'
```

##### Create user with a limit on TPM (Tokens Per Minute) and RPM (Requests Per Minute) and max parallel requests. In this case we give our user 10000 tokens per minute, and 10 requests per minute, and 2 parallel requests.
Note: There is currently a bug where `max_parallel_requests` is not returned in the create user response. However, it is still taking effect, and you can confirm that by doing a GET on the user

```
curl -X POST "https://<Your-Proxy-Endpoint>/user/new" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer <Your-Master-Key-Or-Admin-Key>" \
-d '{
     "user_email": "new_user@example.com",
     "user_role": "internal_user"
     "tpm_limit": 10000,
     "rpm_limit": 10,
     "max_parallel_requests": 2
 }'
```

##### Create a user that can only access Bedrock Claude 3.5 sonnet and Claude 3 Haiku
```
curl -X POST "https://<Your-Proxy-Endpoint>/user/new" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer <Your-Master-Key-Or-Admin-Key>" \
-d '{
     "user_email": "new_user@example.com",
     "user_role": "internal_user"
     "models": ["anthropic.claude-3-5-sonnet-20240620-v1:0", "anthropic.claude-3-haiku-20240307-v1:0"],
 }'
```


##### Create a user that has separate Spends TPM (Tokens Per Minute) limits and RPM (Requests Per Minute) limits for different models 

In this case:
for Claude 3.5 sonnet: 10000 tokens per minute, and 5 requests per minute
for Claude 3 haiku: 20000 tokens per minute, and 10 requests per minute

Note: There is currently a bug where `model_rpm_limit` and `model_tpm_limit` are not returned in the create user response. However, they are still taking effect, and you can confirm that by doing a GET on the user

```
curl -X POST "https://<Your-Proxy-Endpoint>/user/new" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer <Your-Master-Key-Or-Admin-Key>" \
-d '{
     "user_email": "new_user@example.com",
     "user_role": "internal_user"
     "model_rpm_limit": {"anthropic.claude-3-5-sonnet-20240620-v1:0": 1, "anthropic.claude-3-haiku-20240307-v1:0": 1},
     "model_tpm_limit": {"anthropic.claude-3-5-sonnet-20240620-v1:0": 10000, "anthropic.claude-3-haiku-20240307-v1:0": 20000},
 }'
 ```

 ##### Create User Return value

 The return value of `user/new` will look something like this:

 ```
 {"key_alias":null,"duration":null,"models":[],"spend":0.0,"max_budget":1000.0,"user_id":"22bfb70a-fdda-49ce-8447-807149aba3d3","team_id":null,"max_parallel_requests":null,"metadata":{"model_rpm_limit":{"anthropic.claude-3-5-sonnet-20240620-v1:0":1,"anthropic.claude-3-haiku-20240307-v1:0":1},"model_tpm_limit":{"anthropic.claude-3-5-sonnet-20240620-v1:0":10000,"anthropic.claude-3-haiku-20240307-v1:0":20000}},"tpm_limit":null,"rpm_limit":null,"budget_duration":"1mo","allowed_cache_controls":[],"soft_budget":null,"config":{},"permissions":{},"model_max_budget":{},"send_invite_email":null,"model_rpm_limit":null,"model_tpm_limit":null,"guardrails":null,"blocked":null,"aliases":{},"key":"sk-UJwU0Mu_Rs3Iq6ag","key_name":null,"expires":null,"token_id":null,"user_email":"new_user@example.com","user_role":"internal_user","teams":null,"user_alias":null}
 ```

 Copy the `key` value and provide it to your user to begin using the gateway with the configured models, budgets, and quotas

##### Set Priority of request (currently broken: https://github.com/BerriAI/litellm/issues/7144)

To set the priority of a request on the client side, you can do the following:

```
curl -X POST 'https://<Your-Proxy-Endpoint>/v1/chat/completions' \
-H 'Content-Type: application/json' \
-H 'Authorization: Bearer <Your-Master-Key-Or-Admin-Key>' \
-D '{
    "model": "gpt-3.5-turbo-fake-model",
    "messages": [
        {
        "role": "user",
        "content": "what is the meaning of the universe? 1234"
        }],
    "priority": 0 👈 SET VALUE HERE
}'
```

Priority - The lower the number, the higher the priority:
e.g. priority=0 > priority=2000

So if you have traffic you want prioritized over all others, set those calls to priority=0, and the other calls to priority>0

There is currently no way to set this priority on the server side. So you must handle this on the client side for now.



#### Bedrock interface

This deployment has a middleware layer that allows you to use the Bedrock interface via boto3 instead of the OpenAi interface. This requires overriding the `endpoint_url`, and injecting your api key into the authorization header in the request. There are example scripts on how to do this, `test-middleware-synchronous.py` (for synchronous requests) and `test-middleware-streaming.py` (for streaming requests)

To use this script:

Set the required environment variables:

```
export API_ENDPOINT="your-bedrock-endpoint" #Should be https://<Your-Proxy-Endpoint>/bedrock
export API_KEY="your-api-key" #Should be your litellm api key you normally use
export AWS_REGION="your-region" #Should be your deployment region
```

Install dependencies:

`pip install boto3`

Run the script:

`python test-middleware-synchronous.py` (for synchronous requests)

`python test-middleware-streaming.py` (for streaming requests)


The key part of this script is the initialization of the boto3 client, like this:

```
def create_bedrock_client():
    """
    Creates a Bedrock client with custom endpoint and authorization header.
    Uses environment variables for configuration.

    Required environment variables:
    - API_ENDPOINT: Custom Bedrock endpoint URL
    - API_KEY: Authorization bearer token
    - AWS_REGION: AWS region

    Returns:
        boto3.client: Configured Bedrock client
    """

    # Get configuration from environment variables
    endpoint = os.getenv("API_ENDPOINT")
    api_key = os.getenv("API_KEY")
    region = os.getenv("AWS_REGION")

    if not all([endpoint, api_key, region]):
        raise ValueError(
            "Missing required environment variables: API_ENDPOINT, API_KEY, AWS_REGION"
        )

    # Initialize session and configure client
    session = boto3.Session()
    client_config = Config(
        signature_version=UNSIGNED,  # Disable SigV4 signing
        retries={"max_attempts": 10, "mode": "standard"},
    )

    # Create the Bedrock client
    client = session.client(
        "bedrock-runtime",
        endpoint_url=endpoint,
        config=client_config,
        region_name=region,
    )

    # Define authorization header handler
    def add_authorization_header(request, **kwargs):
        request.headers["Authorization"] = f"Bearer {api_key}"

    # Register the event handler
    client.meta.events.register("request-created.*", add_authorization_header)

    return client
```

Once that client is initialized, you can use it exactly as you would use boto3 to call AWS Bedrock directly (currently only supports `converse` and `converse_stream`)

#### Bedrock Managed Prompts

The middleware layer also has support for Bedrock Managed Prompts. It works the same as documented here: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/bedrock-runtime/client/converse.html#

You can use a managed prompt like this:
```
model_id = "arn:aws:bedrock:us-west-2:235614385815:prompt/6LE1KDKISG" #Put the arn of your prompt as the model_id
response = client.converse(
    modelId=model_id,
    promptVariables={ #specify any variables you need for your prompt
        "topic": {"text": "fruit"},
    })
```

The OpenAI Interface also has support for Bedrock Manage Prompts.

You can use a managed prompt like this:

```
model = "arn:aws:bedrock:us-west-2:235614385815:prompt/6LE1KDKISG:2" #Put the arn of your prompt as the model_id

response = client.chat.completions.create(
    model=model,
    messages=[], #Messages is required to be passed in, but it will not be used. Your managed prompt will be used instead
    stream=False,
    extra_body={"promptVariables": {"topic": {"text": "fruit"}}},
)
return response.choices[0].message.content
```

#### Chat History

Middleware layer also supports chat history, via a `session_id`

Note: A `session_id` is tied to a specific api key. Only that api key can access that chat history associated with the session. May eventually make an exception for admins. May eventually allow a single user across multiple api keys to own a `session_id`

To use this with the OpenAI Interface when not using streaming, do the following:

```
response = client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            stream=False,
        )

session_id = response.model_extra.get("session_id")

response_2 = client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": prompt2}],
            stream=False,
            extra_body={"session_id": session_id}
        )
```
The `session_id` is returned as part of the `response.model_extra` dictionary. And you pass that `session_id` in the `extra_body` parameter to continue the same conversation

To use this with the OpenAI Interface with streaming, do the following:

```
stream = client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            stream=True,
        )

session_id = None
first_chunk = True

for chunk in stream:
    # Get session_id from first chunk
    if first_chunk:
        session_id = getattr(chunk, "session_id", None)
        first_chunk = False
    
    #Do normal processing on all chunks

stream2 = client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            stream=True,
            extra_body={"session_id": session_id}
        )
```
The `session_id` is returned as part of the first chunk of the response stream. And you pass that `session_id` in the `extra_body` parameter to continue the same conversation

To use this with the Bedrock interface, do the following:
```
response = client.converse(
                modelId=model_id,
                messages=[{"role": "user", "content": [{"text": message}]}],
            )

session_id = response["ResponseMetadata"]["HTTPHeaders"].get("x-session-id")

response2 = client.converse(
                modelId=model_id,
                additionalModelRequestFields={"session_id": session_id},
                messages=[{"role": "user", "content": [{"text": message2}]}],
            )
```
The `session_id` is returned as a header in `response["ResponseMetadata"]["HTTPHeaders"]`. And you pass that `session_id` in the `additionalModelRequestFields` parameter to continue the same conversation

The approach with Bedrock interface with streaming is identical, but included here for completion:
```
response = client.converse_stream(
                modelId=model_id,
                messages=[{"role": "user", "content": [{"text": message}]}],
            )
session_id = response["ResponseMetadata"]["HTTPHeaders"].get("x-session-id")

response2 = client.converse_stream(
                modelId=model_id,
                messages=[{"role": "user", "content": [{"text": message2}]}],
                additionalModelRequestFields={"session_id": session_id},
            )
```
The `session_id` is returned as a header in `response["ResponseMetadata"]["HTTPHeaders"]`. And you pass that `session_id` in the `additionalModelRequestFields` parameter to continue the same conversation


You can get the chat history for a given session id by calling POST `/chat-history` for history in OpenAI format, or POST `/bedrock/chat-history` for history in AWS Bedrock Converse API format, like this:
```
# Common headers, including authorization
headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}

# Request body containing session_id
payload = {"session_id": session_id}

# Endpoint to get chat history in OpenAI format
openai_url = f"{base_url}/chat-history"
response_openai = requests.post(openai_url, json=payload, headers=headers)

if response_openai.status_code == 200:
    print("OpenAI Format History:")
    print(response_openai.json())
else:
    print("Failed to retrieve OpenAI format history")
    print("Status code:", response_openai.status_code)
    print("Response:", response_openai.text)

# Endpoint to get chat history in Bedrock format
bedrock_url = f"{base_url}/bedrock/chat-history"
response_bedrock = requests.post(bedrock_url, json=payload, headers=headers)

if response_bedrock.status_code == 200:
    print("\nBedrock Format History:")
    print(response_bedrock.json())
else:
    print("Failed to retrieve Bedrock format history")
    print("Status code:", response_bedrock.status_code)
    print("Response:", response_bedrock.text)
```

You can get all session ids for an api key by calling POST `/session-ids` like this:

```
endpoint = f"{base_url}/session-ids"
headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}

response = requests.post(endpoint, headers=headers, json={})
if response.status_code == 200:
    print("Success!")
    print("Session IDs:", response.json().get("session_ids", []))
else:
    print(f"Error: {response.status_code}")
    print(response.text)
```

#### Okta Oauth 2.0 JWT Token Auth Support

This solution supports creating LiteLLM users using an Okta Oauth 2.0 JWT

In your `.env` file, you must provide your `OKTA_ISSUER` (something like https://dev-12345.okta.com/oauth2/default) and your `OKTA_AUDIENCE` (default is `api://default`, but set it to whatever makes sense for your Okta setup)

Any user created with an Okta JWT will be a non admin `internal_user` role. Only someone with the master key (or Admin users/keys derived from the master key) will be able to perform any admin operations. At a later point, we may make it so that someone with a specific Okta claim is able to act as an admin and bypass these restrictions without needing the master key.

Their `user_id` will be the `sub` of the Okta User's claims.

Right now, these users can give themselves any `max_budget`, `tpm_limit`, `rpm_limit`, `max_parallel_requests`, or `teams`. At a later point, we may lock these down more, or make a default configurable in the deployment.

Once you have configured your Okta settings, you can create a user like this:

Request
```
curl -X POST "https://<Your-Proxy-Endpoint>/user/new" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer <Okta Oauth 2.0 JWT>" \
-d '{
 }'
 ```

 Response
 ```
 {"key_alias":null,"duration":null,"models":[],"spend":0.0,"max_budget":1000000000.0,"user_id":"testuser@mycompany.com","team_id":null,"max_parallel_requests":null,"metadata":{},"tpm_limit":null,"rpm_limit":null,"budget_duration":"1mo","allowed_cache_controls":[],"soft_budget":null,"config":{},"permissions":{},"model_max_budget":{},"send_invite_email":null,"model_rpm_limit":null,"model_tpm_limit":null,"guardrails":null,"blocked":null,"aliases":{},"key":"<New_Api_Key_Tied_To_Okta_User>","key_name":null,"expires":null,"token_id":null,"user_email":"testuser@mycompany.com","user_role":"internal_user","teams":null,"user_alias":null}
 ```

With the returned API key, you use LiteLLM as you normally would.

You can also create additional api keys tied to your user:

```
curl -X POST "https://<Your-Proxy-Endpoint>/key/generate" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer <New_Api_Key_Tied_To_Okta_User>" \
-d '{"user_id": "testuser@mycompany.com" }'
```

Reponse
```
{"key_alias":null,"duration":null,"models":[],"spend":0.0,"max_budget":null,"user_id":"testuser@mycompany.com","team_id":null,"max_parallel_requests":null,"metadata":{},"tpm_limit":null,"rpm_limit":null,"budget_duration":null,"allowed_cache_controls":[],"soft_budget":null,"config":{},"permissions":{},"model_max_budget":{},"send_invite_email":null,"model_rpm_limit":null,"model_tpm_limit":null,"guardrails":null,"blocked":null,"aliases":{},"key":"<Second_Api_Key_Tied_To_Okta_User>","key_name":"sk-...fbcg","expires":null,"token_id":"8bb9cb70ce3ed3b7907dfbaae525e06a2fec6601dbe930b5571c0aca12552378"}     
```

#### Langsmith support

To use langsmith, provide your LANGSMITH_API_KEY, LANGSMITH_PROJECT, and LANGSMITH_DEFAULT_RUN_NAME in your .env file

## Open Source Library

For detailed information about the open source libraries used in this application, please refer to the [ATTRIBUTION](ATTRIBUTION.md) file.

