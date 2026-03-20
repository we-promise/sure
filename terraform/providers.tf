terraform {
  backend "s3" {
    bucket = "terraform-remote-states-chancen"
    key    = "aws/companion"
    region = "af-south-1"
    acl    = "bucket-owner-full-control"
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  required_version = "~> 1.14"
}

provider "aws" {
  region = "af-south-1"
  assume_role {
    role_arn = "arn:aws:iam::568619624687:role/terraform"
  }
}