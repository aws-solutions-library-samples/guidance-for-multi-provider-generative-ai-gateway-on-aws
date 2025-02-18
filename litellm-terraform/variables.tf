###############################################################################
# Variables (corresponding to your LiteLLMStackProps)
###############################################################################
variable "stack_name" {
  type        = string
  description = "Name or ID of the stack (used as a tag)"
}

variable "region" {
  type        = string
  description = "The AWS region to deploy into"
}

variable "domainName" {
  type        = string
  description = "Domain name (e.g., 'api.example.com')"
}

variable "hostedZoneName" {
  type        = string
  description = "Hosted Zone Name (e.g., 'example.com')"
}

# variable "certificateArn" {
#   type        = string
#   description = "ACM Certificate ARN"
# }

variable "publicLoadBalancer" {
  type        = bool
  description = "If true, use existing public hosted zone; if false, create private hosted zone"
}

variable "vpcId" {
  type        = string
  description = "Existing VPC ID"
}

variable "rdsLitellmSecretArn" {
  type        = string
  description = "Secrets Manager ARN of the LiteLLM RDS credentials"
}

variable "rdsMiddlewareSecretArn" {
  type        = string
  description = "Secrets Manager ARN of the Middleware RDS credentials"
}

variable "rdsLitellmHostname" {
  type        = string
  description = "Hostname for LiteLLM RDS"
}

variable "rdsMiddlewareHostname" {
  type        = string
  description = "Hostname for Middleware RDS"
}

variable "rdsSecurityGroupId" {
  type        = string
  description = "Security group ID for RDS"
}

variable "redisSecurityGroupId" {
  type        = string
  description = "Security group ID for Redis"
}

variable "redisHostName" {
  type        = string
  description = "Redis endpoint hostname"
}

variable "redisPort" {
  type        = string
  description = "Redis port"
}

variable "openaiApiKey" {
  type        = string
  description = "OpenAI API key"
}

variable "azureOpenAiApiKey" {
  type        = string
  description = "Azure OpenAI API key"
}

variable "azureApiKey" {
  type        = string
  description = "Azure API key"
}

variable "anthropicApiKey" {
  type        = string
  description = "Anthropic API key"
}

variable "groqApiKey" {
  type        = string
  description = "Groq API key"
}

variable "cohereApiKey" {
  type        = string
  description = "Cohere API key"
}

variable "coApiKey" {
  type        = string
  description = "co API key"
}

variable "hfToken" {
  type        = string
  description = "HF token"
}

variable "huggingfaceApiKey" {
  type        = string
  description = "HuggingFace API key"
}

variable "databricksApiKey" {
  type        = string
  description = "Databricks API key"
}

variable "geminiApiKey" {
  type        = string
  description = "Gemini API key"
}

variable "codestralApiKey" {
  type        = string
  description = "Codestral API key"
}

variable "mistralApiKey" {
  type        = string
  description = "Mistral API key"
}

variable "azureAiApiKey" {
  type        = string
  description = "Azure AI API key"
}

variable "nvidiaNimApiKey" {
  type        = string
  description = "Nvidia Nim API key"
}

variable "xaiApiKey" {
  type        = string
  description = "XAI API key"
}

variable "perplexityaiApiKey" {
  type        = string
  description = "PerplexityAI API key"
}

variable "githubApiKey" {
  type        = string
  description = "GitHub API key"
}

variable "deepseekApiKey" {
  type        = string
  description = "DeepSeek API key"
}

variable "ai21ApiKey" {
  type        = string
  description = "AI21 API key"
}

variable "langsmithApiKey" {
  type        = string
  description = "LangSmith API key"
}

variable "liteLLMVersion" {
  type        = string
  description = "LiteLLM version"
}

variable "architecture" {
  type        = string
  description = "Container architecture"
}

variable "ecrLitellmRepository" {
  type        = string
  description = "Name of the LiteLLM ECR repository"
}

variable "ecrMiddlewareRepository" {
  type        = string
  description = "Name of the Middleware ECR repository"
}

variable "logBucketArn" {
  type        = string
  description = "Logging bucket ARN (if needed; not used in code snippet)"
}

# If you want to replicate more, add them here:
variable "oktaIssuer" {
  type        = string
  description = "Okta Issuer"
}

variable "oktaAudience" {
  type        = string
  description = "Okta Audience"
}

variable "langsmithProject" {
  type        = string
  description = "LangSmith project"
}

variable "langsmithDefaultRunName" {
  type        = string
  description = "LangSmith default run name"
}