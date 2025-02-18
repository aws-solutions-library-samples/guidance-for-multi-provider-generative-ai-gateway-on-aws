provider "aws" {
  region = var.region
  default_tags {
    tags = {
      "stack-id" = var.stack_name
      "project"  = "llmgateway"
    }
  }
}

terraform {
  backend "s3" {}
}