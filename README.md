# AWS GenAI Gateway

Project ACTIVE as of Feb 15, 2025

## Table of contents

- [Project Overview](#project-overview)
- [Architecture](#architecture)
- [How to deploy](#how-to-deploy)
    - [Okta Oauth 2.0 JWT Token Auth Support](#okta-oauth-20-jwt-token-auth-support)
    - [Langsmith support](#langsmith-support)
    - [Setting up bastion host in your VPC to allow access to the private load balancer in the case you set PUBLIC_LOAD_BALANCER="false"](#setting-up-bastion-host-in-your-vpc-to-allow-access-to-the-private-load-balancer-in-the-case-you-set-public_load_balancerfalse)
    - [Load testing](#load-testing)
- [Open Source Library](#open-source-library)
- [Notices](#notices)

## Project Overview

This project provides a simple Terraform deployment of LiteLLM into ECS or EKS on AWS. It aims to be pre-configured with defaults that will allow most users to quickly get started with LiteLLM.

It also provides additional features on top of LiteLLM such as an AWS Bedrock Interface (instead of the default OpenAI interface), support for AWS Bedrock Managed Prompts, Chat History, and support for Okta Oauth 2.0 JWT Token Auth.

If you are unfamiliar with LiteLLM, it provides a consistent interface to access all LLM providers so you do not need to edit your code to try out different models. It allows you to centrally manage and track LLM usage across your company at the user, team, and api key level. You can configure budgets and rate limits, restrict access to specific models, and set up retry/fallback routing logic across multiple providers. It provides cost saving measures like prompt caching. It provides security features like support for AWS Bedrock Guardrails for all LLM providers. Finally, it provides a UI where administrators can configure their users and teams, and users can generate their api keys and test out different LLMs in a chat interface.

## Architecture

![Reference Architecture Diagram ECS EKS](./media/Reference_architecture_ECS_EKS_platform_combined.jpg)

### AWS Services in this Guidance

| **AWS Service**                                                                                         | **Role**           | **Description**                                                                                             |
| ------------------------------------------------------------------------------------------------------- | ------------------ | ----------------------------------------------------------------------------------------------------------- |
| [Amazon Bedrock](https://aws.amazon.com/bedrock/)                                    | Core service       | Manages Single API access to multiple Foundational Models                                                   |
| [Amazon Elastic Container Service](https://aws.amazon.com/ecs/) ( ECS)               | Core service       | Manages application platform and on-demand infrastructure for LiteLLM container orchestration.              |
| [Amazon Elastic Kubernetes Service](https://aws.amazon.com/eks/) ( EKS)              | Core service       | Manages Kubernetes control plane and compute nodes for LiteLLM container orchestration.                     |
| [Amazon Elastic Compute Cloud](https://aws.amazon.com/ec2/) (EC2)                    | Core service       | Provides compute instances for EKS compute nodes and runs containerized applications.                       |
| [Amazon Virtual Private Cloud](https://aws.amazon.com/vpc/) (VPC)                    | Core Service       | Creates an isolated network environment with public and private subnets across multiple Availability Zones. |
| [Amazon Web Applications Firewall](https://aws.amazon.com/waf/) (WAF)                | Core Service       | Protect guidance applications from common exploits                                                          |
| [Amazon Elastic Container Registry](http://aws.amazon.com/ecr/) (ECR)                | Supporting service | Stores and manages Docker container images for EKS deployments.                                             |
| [Elastic Load Balancer](https://aws.amazon.com/elasticloadbalancing/) (ALB)          | Supporting service | Distributes incoming traffic across multiple targets in the EKS cluster.                                    |
| [Amazon Simple Storage Service (S3)](https://aws.amazon.com/s3)                      | Supporting service | Provides persistent object storage for Applications logs and other related data.                            |
| [Amazon Relational Database Service ](https://aws.amazon.com/rds/) (RDS)             | Supporting service | Enables persistence of virtual API keys and other configuration settings provided by LiteLLM.               |
| [Amazon ElastiCache Service (Redis OSS) ](https://aws.amazon.com/elasticache/) (OSS) | Supporting service | Enables multi-tenant distribution of application settings and prompt caching.                               |
| [AWS Route 53](https://aws.amazon.com/route53/)                                      | Supporting Service | Routes users to the guidance application via DNS records                                                    |
| [AWS Identity and Access Management](https://aws.amazon.com/iam/) (IAM)              | Supporting service | Manages access to AWS services and resources securely, including ECS or EKS cluster access.                 |
| [AWS Certificate Manager](https://aws.amazon.com/certificate-manager/) (ACM)         | Security service   | Manages SSL/TLS certificates for secure communication within the cluster.                                   |
| [Amazon CloudWatch](https://aws.amazon.com/cloudwatch/)                              | Monitoring service | Collects and tracks metrics, logs, and events from EKS and other AWS resources provisoned in the guidance   |
| [AWS Secrets Manager](https://aws.amazon.com/secrets-manager/)                       | Management service | Manager stores external model provider credentials and other sensitive settings securely.                   |
| [AWS Key Management Service](https://aws.amazon.com/kms/) (KMS)                      | Security service   | Manages encryption keys for securing data in EKS and other AWS services.                                    |

**NOTE** For any guidance deployment, either Amazon ECS or EKS container orchestration platform can be used, but not both.

## Plan your deployment

<!-- Include all deployment planning topics under this section, such as costs,system requirements, deployment pre-requisites, service quotas,
Region considerations, and template dependencies.-->

### Prerequisites

## Cost

### Cost Considerations

When implementing this solution on AWS, it's important to understand the various factors that contribute to the overall cost. This section outlines the primary cost components and key factors that influence pricing.

### Cost Components

The total cost of running this solution can be broadly categorized into two main components:

1. **LLM Provider Costs**: These are the charges incurred for using services from LLM providers such as Amazon Bedrock, Amazon SageMaker, Anthropic, and others. Each provider has its own pricing model, typically based on factors like the number of tokens processed, model complexity, and usage volume.

2. **AWS Infrastructure Costs**: These are the costs associated with running the Gen AI Gateway proxy server on AWS infrastructure. This includes various AWS services and resources used to host and operate the solution.

### Key Factors Influencing AWS Infrastructure Costs

While the default configuration provides a starting point, the actual cost of running the LiteLLM-based proxy server on AWS can vary significantly based on your specific implementation and usage patterns. Some of the major factors that can impact scaling and cost include:

1. **Compute Instances**: The type and number of EC2 instances used to host the LiteLLM container as a proxy. Instance type selection affects both performance and cost.

2. **EBS Storage**: The type and size of EBS volumes attached to the EC2 instances can influence both performance and cost.

3. **Autoscaling Configuration**: The autoscaling policies configured for EKS/ECS clusters will affect how the solution scales in response to demand, impacting both performance and cost.

4. **Traffic Patterns**: The shape and distribution of LLM requests, including factors such as:

   - Request/response payload sizes
   - Tokens per minute (TPM)
   - Requests per minute (RPM)
   - Concurrency levels
   - Model latency (from downstream LLM providers)
   - Network latency between AWS and LLM providers

5. **Caching Configuration**: Effective caching can reduce the number of requests to LLM providers, potentially lowering costs but requiring additional resources.

6. **Database Storage**: The amount of storage required for managing virtual keys, organizations, teams, users, budgets, and per-request usage tracking.

7. **High Availability and Resiliency**: Configurations for load balancing, routing, and retries can impact both reliability and cost.

8. **Logging Level**: The configured logging level affects storage and potentially network egress costs.

9. **Networking Costs**: This includes data transfer charges and the cost of running NAT gateways for outgoing calls to LLM providers.

It's important to note that this is not an exhaustive list of cost factors, but rather highlights some of the major contributors to the overall cost of the solution.

### Customer Responsibility

While this implementation guide provides default configurations, customers are responsible for:

1. Configuring the solution to their optimal settings based on their specific use case and requirements.
2. Monitoring and managing the costs incurred from running the proxy server on AWS infrastructure.
3. Managing and optimizing the costs associated with their chosen LLM providers.

Customers should regularly review their AWS service usage patterns, adjust configurations as needed, and leverage AWS cost management tools to optimize their spending.

We recommend creating a [budget](https://alpha-docs-aws.amazon.com/awsaccountbilling/latest/aboutv2/budgets-create.html) 
through [AWS Cost Explorer](http://aws.amazon.com/aws-cost-management/aws-cost-explorer/) to
help manage costs. Prices are subject to change and also depend on model provider usage patterns/volume of data. For full details, refer to the pricing webpage for each AWS service used in this guidance.

### Sample cost table

The following tables provide a sample cost breakdown for deploying this guidance on Amazon ECS and EKS orchestration platforms with the default parameters in the `us-east-1` (N. Virginia) region for one month. This estimates are based on the AWS Pricing Calculator outputs for the full deployments as per guidance and are subject to changes in underlying services configuration.

**For ECS container orchestration platform**

| **AWS service**                          | Dimensions                                                                                        | Cost, month [USD] |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------- | ----------------- |
| Amazon Elastic Container Service (ECS)   | OS: Linux, CPU Architecture: ARM, 24 hours, 2 tasks per day, 4 GB Memory, 20 GB ephemeral storage | 115.33            |
| Amazon Virtual Private Cloud (VPC)       | 1 VPC, 4 subnets, 1 NAT Gateway, 1 public IPv4, 100 GB outbound data per month                    | 50.00             |
| Amazon Elastic Container Registry (ECR)  | 5 GB image storage/month                                                                          | 0.50              |
| Amazon Elastic Load Balancer (ALB)       | 1 ALB, 1 TB/month                                                                                 | 24.62             |
| Amazon Simple Storage Service (S3)       | 100 GB/month                                                                                      | 7.37              |
| Amazon Relational Database Service (RDS) | 2 db.t3.micro nodes, 100% utilzation, multi-AZ, 2 vCPU,1 GiB Memory                               | 98.26             |
| Amazon ElastiCache Service (Redis OSS)   | 2 cache.t3.micro nodes, 2 vCPU, 0.5 GiB Memory, Upto 5 GB Network performance, 100% utilization   | 24.82             |
| Amazon Route 53                          | 1 hosted zone, 1 millon standard queries/month                                                    | 26.60             |
| Amazon CloudWatch                        | 25 metrics to preserve                                                                            | 12.60             |
| AWS Secrets Manager                      | 5 secrets, 30 days, 1 million API calls per month                                                 | 7.00              |
| AWS Key Management Service (KMS)         | 1 key, 1 millon symmertic requests                                                                | 4.00              |
| AWS WAF                                  | 1 web ACL, 2 rules                                                                                | 7.00              |
| AWS Certificate Manager                  | 1 Certificate                                                                                     | free              |
| **TOTAL**                                |                                                                                                   | **$378.10/month** |

For detailed cost estimates for ECS platform, it is recommended to create an AWS Price calculator like [this:](https://calculator.aws/#/estimate?id=8bce7fe949694f4ddbb08c9974ddcda9d13b1398)

**For EKS container orchestration platform:**

| **AWS service**                          | Dimensions                                                                                      | Cost, month [USD] |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------- | ----------------- |
| Amazon Elastic Kubernetes Service (EKS)  | 1 control plane                                                                                 | 73.00             |
| Amazon Elastic Compute Cloud (EC2)       | EKS Compute Nodes, 2 nodes t4g.medium                                                           | 49.06             |
| Amazon Virtual Private Cloud (VPC)       | 1 VPC, 4 subnets, 1 NAT Gateway, 1 public IPv4, 100 GB outbound data per month                  | 50.00             |
| Amazon Elastic Container Registry (ECR)  | 5 GB image storage/month                                                                        | 0.50              |
| Amazon Elastic Load Balancer (ALB)       | 1 ALB, 1 TB/month                                                                               | 24.62             |
| Amazon Simple Storage Service (S3)       | 100 GB/month                                                                                    | 7.37              |
| Amazon Relational Database Service (RDS) | 2 db.t3.micro nodes, 100% utilzation, multi-AZ, 2 vCPU,1 GiB Memory                             | 98.26             |
| Amazon ElastiCache Service (Redis OSS)   | 2 cache.t3.micro nodes, 2 vCPU, 0.5 GiB Memory, Upto 5 GB Network performance, 100% utilization | 24.82             |
| Amazon Route 53                          | 1 hosted zone, 1 millon standard queries/month                                                  | 26.60             |
| Amazon CloudWatch                        | 25 metrics to preserve                                                                          | 12.60             |
| AWS Secrets Manager                      | 5 secrets, 30 days, 1 million API calls per month                                               | 7.00              |
| AWS Key Management Service (KMS)         | 1 key, 1 millon symmertic requests                                                              | 4.00              |
| AWS WAF                                  | 1 web ACL, 2 rules                                                                              | 7.00              |
| AWS Certificate Manager                  | 1 Certificate                                                                                   | free              |
| **TOTAL**                                |                                                                                                 | **$384.83/month** |

For detailed cost estimates for EKS platform, it is recommended to create an AWS Price calculator like [this:](https://calculator.aws/#/estimate?id=2e331688341278d6e3e1a8b38c8ba76756e71f08)

## Security

When you build systems on AWS infrastructure, security responsibilities are shared between you and AWS. This [shared responsibility model](https://aws.amazon.com/compliance/shared-responsibility-model/) reduces your operational burden because AWS operates, manages, and controls the components including the host operating system, the virtualization layer, and the physical security of the facilities in which the services operate. For more information about AWS security, visit [AWS Cloud Security](http://aws.amazon.com/security/).

This guidance implements several security best practices and AWS services to enhance the security posture of your ECS or EKS Clusters. Here are the key security components and considerations:

### Identity and Access Management (IAM)

- **IAM Roles**: The architecture deploys dedicated IAM roles (`litellm-stack-developers`, `litellm-stack-operators`) to manage access to ECS or EKS cluster resources. This follows the principle of least privilege, ensuring users and services have only the permissions necessary to perform their tasks.
- **EKS Managed Node Groups**: These groups use created IAM roles (`litellm-stack-eks-nodegroup-role`) with specific permissions required for nodes to join the cluster and for pods to access AWS services.

### Network Security

- **Amazon VPC**: ECS or EKS clusters are deployed within a VPC (newly created or custom specified in guidance deployment configuration) with public and private subnets across multiple Availability Zones, providing network isolation.
- **Security Groups**: Security groups are typically used to control inbound and outbound traffic to EC2 instances and other resources within the VPC.
- **NAT Gateways**: Deployed in public subnets to allow outbound internet access for resources in private subnets while preventing inbound access from the internet.

### Data Protection

- **Amazon EBS Encryption**: EBS volumes used by EC2 instances for EKS compute nodes are typically encrypted to protect data at rest.
- **AWS Key Management Service (KMS)**: used for managing encryption keys for various services, including EBS volume encryption.
- **AWS Secrets manager**: used for stores external model providers credentials and other sensitive settings securely.

### Kubernetes-specific Security

- **Kubernetes RBAC**: Role-Based Access Control is implemented within the EKS cluster to manage fine-grained access to Kubernetes resources.
- **AWS Certificate Manager**: Integrated to manage SSL/TLS certificates for secure communication within the clusters.
- **AWS Identity and Access Manager**: used for role/policy based access to AWS services and resources, including ECS or EKS cluster resource access

### Monitoring and Logging

- **Amazon CloudWatch**: Used for monitoring and logging of AWS resources and applications running on the EKS cluster.

### Container Security

- **Amazon ECR**: Stores container images in a secure, encrypted repository. It includes vulnerability scanning to identify security issues in your container images.

### Secrets Management

- **AWS Secrets Manager**: Secrets Manager stores external model provider credentials and other sensitive settings securely.

### Additional Security Considerations

- Regularly update and patch ECS or EKS clusters, compute nodes, and container images.
- Implement network policies to control pod-to-pod communication within the cluster.
- Use Pod Security Policies or Pod Security Standards to enforce security best practices for pods.
- Implement proper logging and auditing mechanisms for both AWS and Kubernetes resources.
- Regularly review and rotate IAM and Kubernetes RBAC permissions.

### Supported AWS Regions

As of March, 2025 Guidance for Multi-Provider Generative AI Gateway on AWS is supported in the following AWS Regions:

| **Region Name**               |
| ----------------------------- |
| US East (Ohio)                |
| US East (N. Virginia)         |
| US West (Northern California) |
| US West (Oregon)              |
| Europe (Paris)                |

### Quotas

Service quotas, also referred to as limits, are the maximum number of service resources or operations for your AWS account.

### Quotas for AWS services in this Guidance

Make sure you have sufficient quota for each of the services implemented in this guidance. For more information, see [AWS service
quotas](https://docs.aws.amazon.com/general/latest/gr/aws_service_limits.html).

To view the service quotas for all AWS services in the documentation without switching pages, view the information in the [Service endpoints and
quotas](https://docs.aws.amazon.com/general/latest/gr/aws-general.pdf#aws-service-information) page in the PDF instead.

## How to deploy

Please see detaild depoyment instructions in the Implementation Guide [here](https://implementationguides.kits.eventoutfitters.aws.dev/rgai-proxy-0130/ai-ml/running-generative-ai-gateway-proxy.html)

**TO DO: UPDATE TO LIVE IG URL ONCE AVAILABLE**

<!--
### Prerequisites

1. Docker
2. AWS CLI
3. Terraform
4. yq (install with brew if on Mac, download binaries if on Linux (see `Installing yq` below))

If you have `DEPLOYMENT_PLATFORM` set to `EKS`:

5. kubectl

### Installing kubectl

On Mac
```
brew install kubectl
```

On Linux

https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/


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
yq: version 4.40.5
Terraform: v1.5.7
kubectl Client Version: v1.32.1
kubectl Kustomize Version: v5.5.0
```

### Deploying from AWS Cloud9 (Optional)

If it's easier for you, you can deploy from an AWS Cloud9 environment using the following steps:

ℹ️ AWS Cloud9 is no longer available to new customers. Existing customers of AWS Cloud9 can continue to use the service as normal.

1. Go to Cloud9 in the console
2. Click `Create environment`
3. Change `Instance Type` to `t3.small` (need to upgrade from micro for Docker to run effectively)
4. Leave rest as default, and click `Create`
5. Once, the environment is deployed, click `Open` under `Cloud9 IDE`
6. In the terminal, run the following commands:
7. `git clone https://github.com/aws-samples/genai-gateway.git`
8. 'cd genai-gateway/' and run `sudo ./install-cloud9-prerequisites.sh` (This will install `jq`, `terraform`, and `kubectl` for you. All other dependencies are pre-installed on Cloud9)
9. Due to a limitation in Cloud 9, the built-in credentials only last 15 minutes. This will always cause your deployments to fail. To avoid this, you MUST do the following
  * Open up the credentials file via `vi ~/.aws/credentials`
  * Paste in your own credentials that have admin access, and will last at least an hour.
  * It will ask you to reenable managed credentials. Leave it disabled. This is the ONLY way you'll get through this deployment successfully.
10. Run the `Deployment Steps` described below

### Creating your certificate

#### Domain and Certifcate, AWS Internal

1. Reach out to mirodrr for instructions on this

#### Domain and Certificate, AWS Customer

1. Follow the instructions [here](https://docs.aws.amazon.com/acm/latest/userguide/gs-acm-request-public.html) to create a certificate with AWS Certificate Manager.

2. Follow the instructions [here](https://docs.aws.amazon.com/acm/latest/userguide/domain-ownership-validation.html) to validate your domain ownership for your certificate.


#### Deployment Steps

*Note:* This will deploy to your "current region", defined as the region your aws cli is currently pointed to. You can check this by running `aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]'` See [this](https://stackoverflow.com/a/63496689) for more details

1. Run `cp .env.template .env`
2. In `.env`, set the `TERRAFORM_S3_BUCKET_NAME` to a globally unique bucket name. This will store your `.tfstate` files for your terraform deployment.
3. In `.env`, set the `CERTIFICATE_ARN` to the ARN of the certificate you created in the `Creating your certificate` section of this README.
4. In `.env`, set the `RECORD_NAME` to the sub domain you created in the `Creating your certificate` section of this README.
5. In `.env`, set the `HOSTED_ZONE_NAME` to the hosted zone you created in the `Creating your certificate` section of this README.
6. In `.env`, Fill out any API Keys you need for any third party providers. If you only want to use Amazon Bedrock, you can just leave the `.env` file as-is
7. By default, this solution is deployed with redis caching enabled, and with most popular model providers enabled. If you want to remove support for certain models, or add more models, you can create and edit your own `config/config.yaml` file. If not, the deployment will automatically use the `config/default-config.yaml`. Make sure you [enable model access](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access-modify.html) on Amazon Bedrock.
8. Make sure you have valid AWS credentials configured in your environment before running the next step. The credentials must last at least an hour to ensure the deployment can complete successfully
9. Run `./deploy.sh`
10. After the deployment is done, you can visit the UI by going to the url at the stack output `ServiceURL`, which is the `RECORD_NAME` you configured earlier.
11. The master api key is stored in AWS Secrets Manager in the `LiteLLMMasterSalt` secret. This api key can be used to call the LiteLLM API, and is also the default password for the LiteLLM UI.

#### Optional Deployment Configurations

* If you'd like to provide an existing VPC, set `EXISTING_VPC_ID` to your existing VPC. The VPC is expected to have both private and public subnets. The public subnets should have Auto-assign public IPv4 address set to yes. The VPC should also have at least one NAT Gateway. This has been tested with the following VPC specification

* 2 Availabillity Zones
* 1 NAT Gateway
* 1 Internet Gateway
* 2 Public Subnets (Auto assigned public ips enabled, route table pointing to Internet Gateway)
* 2 Private Subnets (Route table pointed to NAT Gateway)

* If you'd like to use EKS instead of ECS, switch `DEPLOYMENT_PLATFORM="ECS"` to `DEPLOYMENT_PLATFORM="EKS"` (Note: Because of limitations with Terraform providers and dependencies, you cannot swtich from EKS to ECS in an active deployment. You must do a `undeploy.sh` first. However, switching from ECS to EKS works fine. Open to Pull Requests or suggestions if anyone can figure out a good way to fix this)

* If you'd like to bring your own EKS cluster, set `EXISTING_EKS_CLUSTER_NAME` to your EKS Cluster name. You must also set `EXISTING_VPC_ID`, and the VPC must be the vpc your EKS Cluster exists in. This has been tested with an new EKS cluster created with EKS Auto Mode disabled, and EKS API Auth enabled (see below image). It also has the following add-ons pre-installed:
  * Amazon EKS Pod Identity Agent
  * Amazon VPC CNI
  * kube-proxy
  * CoreDNS

If you'd like the terraform to install the required add-ons for you, you can set `INSTALL_ADD_ONS_IN_EXISTING_EKS_CLUSTER="true"`

If you're bringing an existing cluster, it is assumed that the role or user deploying this has access to the cluster.

Other configurations are not guaranteed to work. You may have to tweak the terraform yourself to work with your particular existing EKS cluster configuration.
![Verified EKS Cluster Configuration](./media/Tested-Bring-Your-Own-EKS-Cluster-Configuration.png)
![Required add ons](./media/Required-EKS-Add-ons.png)


* If you'd like to run LiteLLM in subnets without outbound internet access, set `DISABLE_OUTBOUND_NETWORK_ACCESS="true"`. Due to lack of internet access, this configuration will only work with AWS Bedrock or SageMaker models. Because of this, you must remove all non-Bedrock/non-SageMaker models from your `config/config.yaml` file. If you do not do this, LiteLLM will fail to start as it will attempt to call third party models over the internet.

* If you'd like the Application Load Balancer to be private to your vpc, set `PUBLIC_LOAD_BALANCER="false"`. To make it more convinient to get access to this private load balancer, we have provided a script to deploy a windows EC2 instance in the same VPC, described in more detail in [Setting up bastion host in your VPC to allow access to the private load balancer in the case you set `PUBLIC_LOAD_BALANCER="false"`
](#setting-up-bastion-host-in-your-vpc-to-allow-access-to-the-private-load-balancer-in-the-case-you-set-public_load_balancerfalse)



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

ℹ️ To update this file without having to redeploy the whole stack, you can use the `update-litellm-config.sh` script.

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
export GATEWAY_URL=<Your-Proxy-Endpoint>
export GATEWAY_API_KEY=<Your-Master-Key-Or-Admin-Key>

curl -X POST "$GATEWAY_URL/v1/chat/completions" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $GATEWAY_API_KEY" \
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
curl -X POST "$GATEWAY_URL/user/new" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $GATEWAY_API_KEY" \
-d '{
     "user_email": "new_user@example.com",
     "user_role": "internal_user"
 }'
```

##### Create User with budget that overrides default (in this example we give a budget of 1000 dollars of spend a month)

```
curl -X POST "$GATEWAY_URL/user/new" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $GATEWAY_API_KEY" \
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
curl -X POST "$GATEWAY_URL/user/new" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $GATEWAY_API_KEY" \
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
curl -X POST "$GATEWAY_URL/user/new" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $GATEWAY_API_KEY" \
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
curl -X POST "$GATEWAY_URL/user/new" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $GATEWAY_API_KEY" \
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
curl -X POST '$GATEWAY_URL/v1/chat/completions' \
-H 'Content-Type: application/json' \
-H 'Authorization: Bearer $GATEWAY_API_KEY' \
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

This deployment has a middleware layer that allows you to use the Bedrock interface via boto3 instead of the OpenAi interface. This requires overriding the `endpoint_url`, and injecting your api key into the authorization header in the request. Below is an example script on how to do this:

Set the required environment variables:

```
export API_ENDPOINT="your-bedrock-endpoint" #Should be https://<Your-Proxy-Endpoint>/bedrock
export API_KEY="your-api-key" #Should be your litellm api key you normally use
export AWS_REGION="your-region" #Should be your deployment region
```

Install dependencies:

`pip install boto3`

Run the below script:

Here is a basic example of initializing and using the boto3 client for use with the gateway:

```
import boto3
import os
from botocore.client import Config
from botocore import UNSIGNED
from typing import Generator, Dict, Any, Optional

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


bedrock_client = create_bedrock_client()
messages = [{"role": "user", "content": [{"text": "Create a list of 3 pop songs."}]}]
model_id = "anthropic.claude-3-5-sonnet-20240620-v1:0"
response = bedrock_client.converse(modelId=model_id, messages=messages)
print(response)
```

#### Bedrock Managed Prompts

The middleware layer also has support for Bedrock Managed Prompts. It works the same as documented here: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/bedrock-runtime/client/converse.html#

You can use a managed prompt like this:
```
model_id = "arn:aws:bedrock:us-west-2:123456789012:prompt/6LE1KDKISG" #Put the arn of your prompt as the model_id
response = client.converse(
    modelId=model_id,
    promptVariables={ #specify any variables you need for your prompt
        "topic": {"text": "fruit"},
    })
```

The OpenAI Interface also has support for Bedrock Manage Prompts.

You can use a managed prompt like this:

```
model = "arn:aws:bedrock:us-west-2:123456789012:prompt/6LE1KDKISG:2" #Put the arn of your prompt as the model_id

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
            extra_body={"enable_history": True}
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
            extra_body={"enable_history": True}
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
                additionalModelRequestFields={"enable_history": True}
            )

session_id = response["ResponseMetadata"]["HTTPHeaders"].get("x-session-id")

response2 = client.converse(
                modelId=model_id,
                messages=[{"role": "user", "content": [{"text": message2}]}],
                additionalModelRequestFields={"session_id": session_id},
            )
```
The `session_id` is returned as a header in `response["ResponseMetadata"]["HTTPHeaders"]`. And you pass that `session_id` in the `additionalModelRequestFields` parameter to continue the same conversation

The approach with Bedrock interface with streaming is identical, but included here for completion:
```
response = client.converse_stream(
                modelId=model_id,
                messages=[{"role": "user", "content": [{"text": message}]}],
                additionalModelRequestFields={"enable_history": True},
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
-->

#### Okta Oauth 2.0 JWT Token Auth Support

This solution supports creating LiteLLM users using an Okta Oauth 2.0 JWT

In your `.env` file, you must provide your `OKTA_ISSUER` (something like https://dev-12345.okta.com/oauth2/default) and your `OKTA_AUDIENCE` (default is `api://default`, but set it to whatever makes sense for your Okta setup)

Any user created with an Okta JWT will be a non admin `internal_user` role. Only someone with the master key (or Admin users/keys derived from the master key) will be able to perform any admin operations. At a later point, we may make it so that someone with a specific Okta claim is able to act as an admin and bypass these restrictions without needing the master key.

Their `user_id` will be the `sub` of the Okta User's claims.

Right now, these users can give themselves any `max_budget`, `tpm_limit`, `rpm_limit`, `max_parallel_requests`, or `teams`. At a later point, we may lock these down more, or make a default configurable in the deployment.

Once you have configured your Okta settings, you can create a user like this:

Request
```
export OKTA_JWT=<Your-Okta-Oauth-2.0-JWT>

curl -X POST "$GATEWAY_URL/user/new" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $OKTA_JWT" \
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
export GATEWAY_API_KEY=<New_Api_Key_Tied_To_Okta_User>

curl -X POST "$GATEWAY_URL/key/generate" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $GATEWAY_API_KEY" \
-d '{"user_id": "testuser@mycompany.com" }'
```

Reponse
```
{"key_alias":null,"duration":null,"models":[],"spend":0.0,"max_budget":null,"user_id":"testuser@mycompany.com","team_id":null,"max_parallel_requests":null,"metadata":{},"tpm_limit":null,"rpm_limit":null,"budget_duration":null,"allowed_cache_controls":[],"soft_budget":null,"config":{},"permissions":{},"model_max_budget":{},"send_invite_email":null,"model_rpm_limit":null,"model_tpm_limit":null,"guardrails":null,"blocked":null,"aliases":{},"key":"<Second_Api_Key_Tied_To_Okta_User>","key_name":"sk-...fbcg","expires":null,"token_id":"8bb9cb70ce3ed3b7907dfbaae525e06a2fec6601dbe930b5571c0aca12552378"}
```

#### Langsmith support

To use langsmith, provide your LANGSMITH_API_KEY, LANGSMITH_PROJECT, and LANGSMITH_DEFAULT_RUN_NAME in your .env file

#### Setting up bastion host in your VPC to allow access to the private load balancer in the case you set `PUBLIC_LOAD_BALANCER="false"`

1. Create a EC2 Key Pair ([Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/create-key-pairs.html))
2. In `.env`, set `EC2_KEY_PAIR_NAME` to your key pair name
3. Run `./create-ec2-to-access-private-load-balancer.sh`
4. The public ip address will be output as `bastion_host_public_ip`. Make note of it for later.
5. Modify the hostnames on your local machine (Instructions for Mac. Windows should be similar, still need to test.)
    * `sudo vim /etc/hosts`
    * update the localhost entry
        * Original: `127.0.0.1 localhost`
        * Modified: `127.0.0.1 localhost <RECORD_NAME specified in .env file>` e.g. `127.0.0.1 localhost genai-gateway.robert.people.aws.dev`
6. Set up an ssh tunnel `ssh -i <your_pem_file.pem> -L 8443:<RECORD_NAME>:443 ec2-user@<bastion_host_public_ip>`
7. Now open a browser and navigate it to `https://<RECORD_NAME>:8443`
8. If all has gone well, you should see the LiteLLM UI


#### Load testing

To assist with load testing, a mock LLM backend can be deployed by the `create-fake-llm-load-testing-server.sh` script.

Configuration is done via the `.env` file, via variables:

```
FAKE_LLM_LOAD_TESTING_ENDPOINT_CERTIFICATE_ARN
FAKE_LLM_LOAD_TESTING_ENDPOINT_HOSTED_ZONE_NAME
FAKE_LLM_LOAD_TESTING_ENDPOINT_RECORD_NAME
```

Procedure for these settings is similar to the one described in the [Deployment steps](#deployment-steps), but you need to use a different name for the record and different certificate, the hosted zone can be reused.

This will deploy a simple HTTP backend that exposes 3 APIs for use via HTTP POST:
* `/model/{model_id}/converse`

   Returns a single JSON response according to the Bedrock response schema. The model_id is ignored.
* `/chat/completions`
* `/v1/chat/completions`

  The 2 completion endpoints either return:
  - A normal (non-streaming) completion with a random 1–3 second delay
  - A streaming response with multiple chunks and random 0.2–0.8 second delays

To cleanup the mock LLM backend, run `delete-fake-llm-load-testing-server.sh`.

## Open Source Library

For detailed information about the open source libraries used in this application, please refer to the [ATTRIBUTION](ATTRIBUTION.md) file.

## Notices 

Customers are responsible for making their own independent assessment of the information in this Guidance. This Guidance: (a) is for informational purposes only, (b) represents AWS current product offerings and practices, which are subject to change without notice, and (c) does not create any commitments or assurances from AWS and its affiliates, suppliers or licensors. AWS products or services are provided “as is” without warranties, representations, or conditions of any kind, whether express or implied. AWS responsibilities and liabilities to its customers are controlled by AWS agreements, and this Guidance is not part of, nor does it modify, any agreement between AWS and its customers.


