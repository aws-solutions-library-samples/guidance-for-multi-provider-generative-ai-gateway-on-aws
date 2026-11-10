terraform {
  required_version = ">= 1.10" # cross-variable validation (the root modules require >= 1.11)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}
