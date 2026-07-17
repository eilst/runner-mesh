terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # State holds the IAM secret access key — keep it LOCAL and gitignored,
  # or use an encrypted remote backend. Never commit it.
}

provider "aws" {
  region = var.region
  # Auth: standard AWS credential chain (env, ~/.aws, SSO, instance role).
}
