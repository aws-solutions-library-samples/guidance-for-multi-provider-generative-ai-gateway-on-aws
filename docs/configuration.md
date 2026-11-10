# Deployment configuration reference

`deploy/deploy.sh` passes one file, `deploy/terraform.tfvars`, to both root modules. A variable that only one root
declares makes the other print a `Value for undeclared variable` warning; that is expected. The tables follow the
`variables.tf` files, which remain authoritative; regenerate them after a change (for example with
[terraform-docs](https://terraform-docs.io/)). Validation rules are in the `variables.tf` files.

A `config_override_file` and other configuration content that you create and upload are "Your Content" as defined
in the [AWS Customer Agreement](https://aws.amazon.com/agreement/). AWS does not claim ownership of it.

## Shared inputs

Read by both `terraform/foundation` and `terraform/app` (`kms_key_arn` reaches the app as a foundation output).
Descriptions combine both roots.

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `deployment_name` | `string` | required | Name prefix for every resource. Two deployments in one account must use different names. |
| `tags` | `map(string)` | `{}` | Customer tags merged into the default tags applied to every resource. |
| `public_mode` | `bool` | `false` | `false`: internal ALB, reachable from the VPC or the listed client ranges only. `true`: internet-facing ALB with WAF; the foundation creates (or validates) public subnets in two Availability Zones. Cannot be combined with `disable_outbound_network_access` or `allow_insecure_http`. |
| `disable_outbound_network_access` | `bool` | `false` | No-internet mode for the created VPC: no internet gateway, no NAT, AWS services through VPC endpoints only. An IdP, non-Bedrock providers and the online check of older-format licence keys are unreachable without an egress proxy; signed licence keys are verified offline. The app reads it only to warn when an identity provider is unreachable. |
| `kms_key_arn` | `string` | `null` | Optional customer KMS key for the database, Redis, secrets, logs and S3. Null uses AWS-managed keys. |
| `deletion_protection` | `bool` | `true` | Protects the database and the ALB from deletion and keeps the S3 buckets and the LiteLLM, WAF and RDS PostgreSQL log groups on destroy; deploy/undeploy.sh stops before any destroy while it is true. Set to false and deploy before undeploying. |
| `hosted_zone_id` | `string` | `null` | Optional Route 53 hosted zone; with record_name, the app creates an alias to the ALB. Set both or neither. The foundation only validates it: a hosted zone requires your own VPC (`vpc_id`), and the private zone must be associated with that VPC before deployment. |

## Foundation inputs

`terraform/foundation`: network, data stores, generated secrets, demo Client VPN.

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `vpc_id` | `string` | `null` | Bring-your-own VPC ID. Leave null to create a VPC. BYO subnets are listed explicitly and validated at plan time, before anything is created (vpc-validation.tf). |
| `private_subnet_ids` | `list(string)` | `[]` | Bring-your-own VPC only: at least two private subnets in different Availability Zones. |
| `public_subnet_ids` | `list(string)` | `[]` | Bring-your-own VPC, public mode only: public subnets in at least two Availability Zones for the internet-facing entry point. |
| `vpc_cidr` | `string` | `"10.0.0.0/16"` | IPv4 CIDR for the created VPC. Ignored for a bring-your-own VPC. Scale-out needs free addresses in the private subnets; use a larger range if heavy traffic is expected. |
| `create_vpc_endpoints_in_existing_vpc` | `bool` | `false` | Bring-your-own VPC only: create the VPC endpoints in it (the S3 gateway endpoint; interface endpoints follow create_interface_endpoints / disable_outbound_network_access). Leave false when the VPC already has them. |
| `create_interface_endpoints` | `bool` | `false` | Create the interface VPC endpoints (Secrets Manager, ECR, CloudWatch Logs, STS, Bedrock runtime) even though the VPC has internet egress. Created automatically in no-internet mode. Each endpoint costs per hour per Availability Zone; with a NAT gateway the traffic works without them. |
| `egress_proxy_configured` | `bool` | `false` | An HTTPS proxy handles outbound traffic from the private subnets. Only suppresses the no-egress warning; the proxy itself is configured on the gateway. |
| `extra_data_ingress_security_group_ids` | `list(string)` | `[]` | Extra security groups admitted to RDS and Redis, for any non-ECS client of the data stores (for example pods on an EKS cluster). |
| `extra_data_ingress_cidrs` | `list(string)` | `[]` | Extra CIDR ranges admitted to RDS and Redis, for any non-ECS client of the data stores. |
| `destroy_data_without_snapshot` | `bool` | `false` | Throwaway deployments only: on destroy, delete the database WITHOUT a final snapshot and delete its automated backups. Default false: every destroy leaves a final snapshot and keeps the automated backups. |
| `create_vpn` | `bool` | `false` | Create the demo/test Client VPN into the VPC (mutual TLS, split tunnel, VPC range only). For testing only; use Direct Connect, Transit Gateway or your own VPN for regular access. Run deploy/setup-vpn.sh certs first for the two certificate ARNs. |
| `vpn_server_certificate_arn` | `string` | `null` | ACM ARN of the Client VPN server certificate (printed by deploy/setup-vpn.sh certs). Required when create_vpn. |
| `vpn_client_root_certificate_arn` | `string` | `null` | ACM ARN whose chain validates the VPN client certificate (printed by deploy/setup-vpn.sh certs). Required when create_vpn. |
| `vpn_client_cidr` | `string` | `"10.250.0.0/22"` | Address range VPN clients get (a /12 to /22 that must not overlap the VPC CIDR). |

## App inputs

`terraform/app`: load balancer, WAF, ECS service, LiteLLM configuration, IAM, logs, alarms.

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `certificate_arn` | `string` | `null` | The customer's ACM certificate for the ALB HTTPS listener. Required unless allow_insecure_http. |
| `allow_insecure_http` | `bool` | `false` | Private trials only: serve plain HTTP without a certificate. Rejected in public mode. |
| `record_name` | `string` | `null` | Optional DNS name (for example llm.example.com) created in hosted_zone_id. Set both or neither. |
| `identity_provider` | `object` | `null` | Optional OIDC identity provider. When set, the ALB requires sign-in in front of the LiteLLM UI paths — unconditionally, in private and public mode alike. The client secret is given as a Secrets Manager ARN; its value does not pass through variables. |
| `litellm_license_secret_arn` | `string` | `null` | Optional Secrets Manager ARN of the LiteLLM Enterprise licence. Null runs LiteLLM's open-source feature set. |
| `client_cidrs` | `list(string)` | `[]` | Private mode: CIDR ranges allowed to reach the ALB (VPN, Direct Connect, Transit Gateway). Empty means the VPC CIDR only, not all of RFC 1918. |
| `client_security_group_ids` | `list(string)` | `[]` | Extra security groups allowed to reach the ALB. The foundation's demo Client VPN is admitted automatically via vpn_security_group_id. |
| `log_level` | `string` | `"INFO"` | LITELLM_LOG level. DEBUG writes prompts and provider payloads to the logs: temporary troubleshooting only; the plan warns while it is on. |
| `config_override_file` | `string` | `null` | Optional YAML file merged over the rendered LiteLLM config: `general_settings`, `litellm_settings` and `router_settings` are merged key by key (the override wins); `model_list` and every other top-level key are taken from the override. A top-level `environment_variables` key replaces the base map: it drops `STORE_MODEL_IN_DB`, so models added in the UI or API are no longer persisted, and its names bypass the `extra_environment` checks; merge it carefully. The file's content lands in Terraform state, plan output and S3: reference secrets as `os.environ/<NAME>` and pass them with `provider_secret_arns`. `deploy/deploy.sh` reads a relative path from `deploy/` (next to `terraform.tfvars`) and passes it on as an absolute path. |
| `bedrock_model_allowlist` | `list(string)` | `[]` | Optional Bedrock model IDs the task role may invoke. Empty = any model and inference profile in the allowed regions (model access is still governed in Bedrock and in LiteLLM teams). With a model allowlist, application inference profiles are not covered, and global cross-Region inference profiles only without a Region allowlist; extend the task role's IAM policy if you need them. |
| `bedrock_region_allowlist` | `list(string)` | `[]` | Optional regions the task role may invoke Bedrock in. Empty = any region, so cross-region inference profiles and new regions keep working. With a Region allowlist, global cross-Region inference profiles are not covered, and a cross-Region profile needs all its destination Regions in the list; extend the task role's IAM policy if you need broader access. |
| `cross_account_role_arns` | `list(string)` | `[]` | Roles in other accounts LiteLLM may assume for Bedrock models or guardrails, listed explicitly. A role/* wildcard is rejected. |
| `provider_secret_arns` | `map(string)` | `{}` | Environment variable name => Secrets Manager ARN (optionally with the :json-key:: suffix) for non-Bedrock provider API keys. Values do not pass through variables or state. Names the stack sets itself are rejected. |
| `extra_environment` | `map(string)` | `{}` | Additional non-secret environment variables for LiteLLM (for example SSO client IDs, PROXY_BASE_URL, HTTPS_PROXY). Names the stack sets itself are rejected; set the log level with log_level. |
| `alarm_email` | `string` | `null` | Optional email address subscribed to the alarm topic (confirm the subscription from the email AWS sends). |
| `image_uri` | `string` | `null` | Override of the LiteLLM image URI, for air-gapped deployments pulling from a private registry (e.g. a copy made with deploy/mirror-image.sh). For a private ECR URI (`<account>.dkr.ecr.<region>.amazonaws.com/<repository>...`) the execution role gets pull rights on that repository only; other registries get no extra permissions. null uses the pinned upstream image. |

## App inputs wired from the foundation

`deploy/deploy.sh` sets these app inputs from `terraform output -json` of the foundation (names match the
foundation outputs one to one), and those values win over `terraform.tfvars`. Network inputs you give the
foundation (`vpc_id`, the subnet IDs) therefore reach the app through the foundation's outputs; there is nothing
else to set:

`vpc_id`, `private_subnet_ids`, `vpc_cidr`, `database_url_secret_arn`, `redis_endpoint`,
`redis_port`, `redis_auth_secret_arn`, `config_bucket_name`, `master_key_secret_arn`, `salt_key_secret_arn`,
`data_ingress_security_group_id`, `public_subnet_ids`, `ui_password_secret_arn`, `rds_instance_identifier`,
`redis_replication_group_id`, `redis_num_cache_clusters`, `vpn_security_group_id`.

## Outputs

`deploy/deploy.sh` saves the foundation outputs (the list above, plus `kms_key_arn`; `db_endpoint` is a foundation
output for other consumers and is left out) to `deploy/.generated/<deployment_name>-foundation-outputs.tfvars.json`,
and prints the app's `service_url`. The secret outputs are Secrets Manager ARNs, not values.

| App output | Description |
| --- | --- |
| `service_url` | The gateway URL clients call (the alias record, or the ALB's own DNS name). |
| `alb_dns_name` | The ALB's own DNS name. |
| `ecs_cluster_name` / `ecs_service_name` | ECS cluster and service. |
| `log_group_name` | The LiteLLM CloudWatch log group. |
| `alarm_topic_arn` | SNS topic receiving alarm and OK notifications. |
| `dashboard_name` | CloudWatch dashboard of the gateway. |
| `alb_arn_suffix` / `target_group_arn_suffix` | CloudWatch metric dimensions. |
