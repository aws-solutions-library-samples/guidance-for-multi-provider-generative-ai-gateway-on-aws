provider "aws" {
  region = var.region
  default_tags {
    tags = {
      "stack-id" = var.name
      "project"  = "llmgateway"
    }
  }
}

terraform {
  backend "s3" {}
}