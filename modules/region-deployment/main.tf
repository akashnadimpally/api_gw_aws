// Accept inputs from root module
variable "region"         { type = string }
variable "api_name"       { type = string }
variable "stage_name"     { type = string }
variable "endpoints"      { type = list(map(string)) }
variable "require_api_key"{ type = bool }
variable "throttle_rate"  { type = number }
variable "throttle_burst" { type = number }

// Create the REST API (Private endpoint type)
resource "aws_api_gateway_rest_api" "api" {
  provider = aws                       // use the region-specific provider
  name        = "${var.api_name}-${var.region}"
  description = "Private multi-region API (${var.region}) - managed by Terraform"
  endpoint_configuration {
    types = ["PRIVATE"]               // Private API Gateway
    // Note: For a private API, you must have VPC Interface Endpoints for execute-api in your VPC.
    // You can optionally specify those VPC Endpoint IDs here to restrict access to specific VPCs:
    // vpc_endpoint_ids = [ "vpce-0123456789abcdef0", ... ] 
  }

  // Require API keys if enabled (via usage plan). This setting works in combination with methods' api_key_required.
  api_key_source = var.require_api_key ? "HEADER" : "HEADER"
}

// Create resources and methods from the YAML endpoints list
// First, create API Gateway Resource for each unique path (except root "/")
locals {
  // Extract unique path parts from endpoints. 
  // We assume paths are given like "/foo/bar". We will create intermediate resources accordingly.
  paths = distinct([for ep in var.endpoints : ep.path])
}

// Create all resource path segments recursively
// Use a map to store resource IDs for each path for lookup
data "aws_api_gateway_resource" "root" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  path        = "/"
}
locals {
  resource_id_by_path = {
    "/" = data.aws_api_gateway_resource.root.id
    # We will fill this via null_resource or dynamic blocks below if needed.
  }
}
