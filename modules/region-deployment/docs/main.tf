# main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  config = yamldecode(file("${path.module}/api-config.yaml"))
}

provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

provider "aws" {
  alias  = "use2"
  region = "us-east-2"
}

module "member_zone_use1" {
  source    = "./modules/member-zone"
  providers = { aws = aws.use1 }

  api_config          = local.config
  existing_vpc_id     = "vpc-12345678"
  existing_subnet_ids = ["subnet-123", "subnet-456"]
  existing_vpce_ids   = ["vpce-12345678"] # From core zone
  route53_zone_name   = "member.example.com"
  region              = "us-east-1"
}

module "member_zone_use2" {
  source    = "./modules/member-zone"
  providers = { aws = aws.use2 }

  api_config          = local.config
  existing_vpc_id     = "vpc-abcdefgh"
  existing_subnet_ids = ["subnet-789", "subnet-012"]
  existing_vpce_ids   = ["vpce-abcdefgh"] # From core zone
  route53_zone_name   = "member.example.com"
  region              = "us-east-2"
}
