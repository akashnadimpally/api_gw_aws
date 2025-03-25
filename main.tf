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
  alias  = "primary"
  region = local.config.regions[0]
}

provider "aws" {
  alias  = "secondary"
  region = local.config.regions[1]
}

module "primary_region" {
  source    = "/Users/akash/Desktop/Infra/skynet_infra/API_GATEWAY/modules/region-deployment"
  providers = { aws = aws.primary }
  
  aws_region        = local.config.regions[0]

  organization_id = "XXXXXXXXXXXXXX"

  lambda_source_path = "${path.module}/modules/region-deployment/lambda/data-processor.zip"  
  api_config      = local.config
  vpc_cidr        = "10.0.0.0/16"
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
}

module "secondary_region" {
  source    = "/Users/akash/Desktop/Infra/skynet_infra/API_GATEWAY/modules/region-deployment"
  providers = { aws = aws.secondary }

  aws_region        = local.config.regions[1] 
  organization_id = "XXXXXXXXXXXXXX"

  lambda_source_path = "${path.module}/modules/region-deployment/lambda/data-processor.zip"  
  api_config      = local.config
  vpc_cidr        = "10.1.0.0/16"
  private_subnets = ["10.1.1.0/24", "10.1.2.0/24"]
}
