terraform {
  required_version = ">= 1.11"

  # Local state by default. To keep it in the gateway's state bucket, add
  #   backend "s3" {}
  # and run terraform init -backend-config="bucket=<bucket>" \
  #   -backend-config="key=loadtest/<name_prefix>.tfstate" -backend-config="use_lockfile=true"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

provider "aws" {
  default_tags {
    tags = { LoadTest = var.name_prefix }
  }
}
