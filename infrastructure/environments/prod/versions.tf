terraform {
  required_version = "= 1.16.4"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }

    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "The Drift Log"
      ManagedBy   = "Terraform"
      Environment = "prod"
    }
  }
}