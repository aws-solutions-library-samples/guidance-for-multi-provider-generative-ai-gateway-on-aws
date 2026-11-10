terraform {
  required_version = ">= 1.11"

  # Configured by scripts/deploy.sh (bucket, key, region, encrypt, use_lockfile).
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.71, < 7.0" # bedrockagentcore resources with EXTERNAL API-key secrets
    }
  }
}

provider "aws" {
  default_tags {
    tags = merge(var.tags, {
      Project   = "llmgateway"
      Example   = "agentcore"
      Agent     = var.name
      ManagedBy = "terraform"
    })
  }
}
