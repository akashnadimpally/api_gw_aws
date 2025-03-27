// Configure AWS providers for each region (primary and secondary)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
provider "aws" {
  alias  = "us_east_2"
  region = "us-east-2"
}

// Load API specification from YAML file
locals {
  api_config = yamldecode(file("${path.module}/api-config.yaml"))
}

// Optional: Default stage name and regions list (could also be passed via variables)
variable "regions" {
  type    = list(string)
  default = ["us-east-1", "us-east-2"]
}
variable "stage_name" {
  type    = string
  default = "prod"
}

// Iterate deployments for each region using the submodule
module "api_deployments" {
  source  = "./region-deployment"
  for_each      = toset(var.regions)        // deploy to each region in the list
  providers = {
    aws = aws[each.key]                    // use the provider for this region
  }

  region       = each.key
  api_name     = local.api_config.api_name
  stage_name   = var.stage_name
  endpoints    = local.api_config.endpoints       // list of endpoint definitions from YAML
  require_api_key = lookup(local.api_config, "require_api_key", false)
  throttle_rate   = lookup(local.api_config, "throttling", {})["rate_limit"]
  throttle_burst  = lookup(local.api_config, "throttling", {})["burst_limit"]
}
