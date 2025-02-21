module "base" {
  source = "./modules/base"
  name = var.name
  vpc_id = var.vpc_id
  deployment_platform = local.platform
  create_vpc_endpoints_in_existing_vpc = var.create_vpc_endpoints_in_existing_vpc
  disable_outbound_network_access = var.disable_outbound_network_access
  ecrLitellmRepository = var.ecrLitellmRepository
  ecrMiddlewareRepository = var.ecrMiddlewareRepository
  hostedZoneName = var.hosted_zone_name
  publicLoadBalancer = var.public_load_balancer
  rds_instance_class = var.rds_instance_class
  rds_allocated_storage = var.rds_allocated_storage
  redis_node_type = var.redis_node_type
  redis_num_cache_clusters = var.redis_num_cache_clusters
}

module "ecs_cluster" {
  source = "./modules/ecs"
  count  = local.platform == "ECS" ? 1 : 0
  name = var.name
  config_bucket_arn = module.base.ConfigBucketArn
  redis_host = module.base.RedisHost
  redis_port = module.base.RedisPort
  redis_password = module.base.RedisPassword
  log_bucket_arn = var.log_bucket_arn
  ecr_litellm_repository_url = module.base.LiteLLMRepositoryUrl
  ecr_middleware_repository_url = module.base.MiddlewareRepositoryUrl
  litellm_version = var.litellm_version
  config_bucket_name = module.base.ConfigBucketName
  openai_api_key = var.openai_api_key
  azure_openai_api_key = var.azure_openai_api_key
  azure_api_key = var.azure_api_key
  anthropic_api_key = var.anthropic_api_key
  groq_api_key = var.groq_api_key
  cohere_api_key = var.cohere_api_key
  co_api_key = var.co_api_key
  hf_token = var.hf_token
  huggingface_api_key = var.huggingface_api_key
  databricks_api_key = var.databricks_api_key
  gemini_api_key = var.gemini_api_key
  codestral_api_key = var.codestral_api_key
  mistral_api_key = var.mistral_api_key
  azure_ai_api_key = var.azure_ai_api_key
  nvidia_nim_api_key = var.nvidia_nim_api_key
  xai_api_key = var.xai_api_key
  perplexityai_api_key = var.perplexityai_api_key
  github_api_key = var.github_api_key
  deepseek_api_key = var.deepseek_api_key
  ai21_api_key = var.ai21_api_key
  langsmith_api_key = var.langsmith_api_key
  langsmith_project = var.langsmith_project
  langsmith_default_run_name = var.langsmith_default_run_name
  okta_audience = var.okta_audience
  okta_issuer = var.okta_issuer
  certificate_arn = var.certificate_arn
  wafv2_acl_arn = module.base.WafAclArn
  domain_name = var.domain_name
  hosted_zone_name = var.hosted_zone_name
  vpc_id = module.base.VpcId
  db_security_group_id = module.base.DbSecurityGroupId
  redis_security_group_id = module.base.RedisSecurityGroupId
  architecture = var.architecture
  disable_outbound_network_access = var.disable_outbound_network_access
  desired_capacity = var.desired_capacity
  min_capacity = var.min_capacity
  max_capacity = var.max_capacity
  public_load_balancer = var.public_load_balancer
  master_and_salt_key_secret_arn = module.base.LitellmMasterAndSaltKeySecretArn
  main_db_secret_arn = module.base.DatabaseUrlSecretArn
  vcpus = var.vcpus
  cpu_target_utilization_percent = var.cpu_target_utilization_percent
  memory_target_utilization_percent = var.memory_target_utilization_percent
  private_subnets = module.base.private_subnet_ids
  public_subnets = module.base.public_subnet_ids

  depends_on = [ module.base ]
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [module.base.VpcId]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["false"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [module.base.VpcId]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

module "eks_cluster" {
  source = "./modules/eks"
  count  = local.platform == "EKS" ? 1 : 0
  name = var.name
  private_subnet_ids = data.aws_subnets.private.ids
  public_subnet_ids  = data.aws_subnets.public.ids
  config_bucket_arn = module.base.ConfigBucketArn
  existing_cluster_name = var.existing_cluster_name
  cluster_version = var.cluster_version
  redis_host = module.base.RedisHost
  redis_port = module.base.RedisPort
  redis_password = module.base.RedisPassword
  log_bucket_arn = var.log_bucket_arn
  ecr_litellm_repository_url = module.base.LiteLLMRepositoryUrl
  ecr_middleware_repository_url = module.base.MiddlewareRepositoryUrl
  litellm_version = var.litellm_version
  config_bucket_name = module.base.ConfigBucketName
  database_url = module.base.database_url
  litellm_master_key = module.base.litellm_master_key
  litellm_salt_key = module.base.litellm_salt_key
  openai_api_key = var.openai_api_key
  azure_openai_api_key = var.azure_openai_api_key
  azure_api_key = var.azure_api_key
  anthropic_api_key = var.anthropic_api_key
  groq_api_key = var.groq_api_key
  cohere_api_key = var.cohere_api_key
  co_api_key = var.co_api_key
  hf_token = var.hf_token
  huggingface_api_key = var.huggingface_api_key
  databricks_api_key = var.databricks_api_key
  gemini_api_key = var.gemini_api_key
  codestral_api_key = var.codestral_api_key
  mistral_api_key = var.mistral_api_key
  azure_ai_api_key = var.azure_ai_api_key
  nvidia_nim_api_key = var.nvidia_nim_api_key
  xai_api_key = var.xai_api_key
  perplexityai_api_key = var.perplexityai_api_key
  github_api_key = var.github_api_key
  deepseek_api_key = var.deepseek_api_key
  ai21_api_key = var.ai21_api_key
  langsmith_api_key = var.langsmith_api_key
  langsmith_project = var.langsmith_project
  langsmith_default_run_name = var.langsmith_default_run_name
  okta_audience = var.okta_audience
  okta_issuer = var.okta_issuer
  certificate_arn = var.certificate_arn
  wafv2_acl_arn = module.base.WafAclArn
  domain_name = var.domain_name
  hosted_zone_name = var.hosted_zone_name
  create_cluster = var.create_cluster
  vpc_id = module.base.VpcId
  db_security_group_id = module.base.DbSecurityGroupId
  redis_security_group_id = module.base.RedisSecurityGroupId
  architecture = var.architecture
  disable_outbound_network_access = var.disable_outbound_network_access
  eks_alb_controller_private_ecr_repository_name = module.base.EksAlbControllerPrivateEcrRepositoryName
  install_add_ons_in_existing_eks_cluster = var.install_add_ons_in_existing_eks_cluster
  desired_capacity = var.desired_capacity
  min_capacity = var.min_capacity
  max_capacity = var.max_capacity
  arm_instance_type = var.arm_instance_type
  x86_instance_type = var.x86_instance_type
  arm_ami_type = var.arm_ami_type
  x86_ami_type = var.x86_ami_type
  public_load_balancer = var.public_load_balancer

  depends_on = [ module.base ]
}