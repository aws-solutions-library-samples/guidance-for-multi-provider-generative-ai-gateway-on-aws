terraform {
  backend "s3" {}
}

locals {
  common_labels = {
    project     = "llmgateway"
  }
}


provider "aws" {
  default_tags {
    tags = local.common_labels
  }
}