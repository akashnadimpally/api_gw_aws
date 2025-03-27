// ============================================================================
// modules/region-deployment/main.tf
// ============================================================================
// This module deploys a private API Gateway in a single region. It creates
// the REST API, its resources and methods from a YAML-defined list of endpoints,
// and configures integration with backend services (Lambda vs. HTTP_PROXY via VPC Link)
// for MRAP. It also creates a usage plan and API key if required.
// ============================================================================

/*-------------------------------------------------------------------------
   REST API Definition
-------------------------------------------------------------------------*/
resource "aws_api_gateway_rest_api" "api" {
  name        = "${var.api_name}-${var.region}"
  description = "Private MRAP API for ${var.api_name} in ${var.region} - managed by Terraform"
  endpoint_configuration {
    types = ["PRIVATE"]
  }
  // API key source will be enforced at the method level.
  api_key_source = "HEADER"
}

/*-------------------------------------------------------------------------
   VPC Link for HTTP Proxy (ECS/EKS integrations)
-------------------------------------------------------------------------*/
// Identify unique backend URIs for ECS/EKS integrations
locals {
  ecs_eks_backends = distinct([
    for ep in var.endpoints :
    ep.backend_uri if (ep.integration_type == "ECS" || ep.integration_type == "EKS")
  ])
}

// Create one VPC Link per unique backend URI.
resource "aws_api_gateway_vpc_link" "vpc_links" {
  for_each = { for uri in local.ecs_eks_backends : uri => uri }
  name     = "${var.api_name}-vpc-link-${replace(each.key, "[^A-Za-z0-9-]", "_")}"
  target_arns = [
    // Assumes the provided backend_uri is an ARN (e.g. of an NLB).
    each.key
  ]
  depends_on = [aws_api_gateway_rest_api.api]
}

/*-------------------------------------------------------------------------
   API Gateway Resources
-------------------------------------------------------------------------*/
// Derive distinct resource paths from the endpoints.
// For simplicity, assume endpoints are top-level paths like "/hello" or "/submit".
// The root resource ("/") is provided by API Gateway.
locals {
  // Filter out the root if defined.
  paths = distinct([for ep in var.endpoints : ep.path if ep.path != "/"])
}

// Create a resource for each unique non-root path.
// The parent for these resources is the API root.
resource "aws_api_gateway_resource" "resources" {
  for_each    = { for p in local.paths : p => p }
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  // Derive the resource name by trimming the leading "/" character.
  path_part   = trim(each.value, "/")
}

/*-------------------------------------------------------------------------
   API Gateway Methods
-------------------------------------------------------------------------*/
// Use a composite key: "<path>-<HTTP_METHOD>" for uniqueness.
locals {
  endpoints_by_key = {
    for ep in var.endpoints : "${ep.path}-${upper(ep.method)}" => ep
  }
}

resource "aws_api_gateway_method" "methods" {
  for_each = local.endpoints_by_key

  rest_api_id = aws_api_gateway_rest_api.api.id
  // For root ("/"), use the API root; otherwise, use the created resource.
  resource_id = each.value.path == "/" ? aws_api_gateway_rest_api.api.root_resource_id
                : aws_api_gateway_resource.resources[each.value.path].id
  http_method       = upper(each.value.method)
  authorization     = "NONE"
  api_key_required  = var.require_api_key

  // If a request model is defined (as a map, e.g. { "application/json" = "ModelName" }),
  // attach it to the method.
  dynamic "request_models" {
    for_each = lookup(each.value, "request_models", {}) != {} ? [lookup(each.value, "request_models", {})] : []
    content {
      for ct, model in request_models.value : ct => model
    }
  }
}

/*-------------------------------------------------------------------------
   API Gateway Integrations
-------------------------------------------------------------------------*/
// Create an integration for each method.
// We use the same key as the method resource.
resource "aws_api_gateway_integration" "integration" {
  for_each    = local.endpoints_by_key

  rest_api_id = aws_api_gateway_rest_api.api.id
  // Re-use the resource from the method.
  resource_id = aws_api_gateway_method.methods[each.key].resource_id
  http_method = aws_api_gateway_method.methods[each.key].http_method

  // Determine integration configuration based on integration_type.
  dynamic "integration_configuration" {
    for_each = [each.value]
    content {
      // For Lambda integration: force POST and construct the URI accordingly.
      integration_http_method = each.value.integration_type == "Lambda" ? "POST" : upper(each.value.method)
      type = each.value.integration_type == "Lambda" ? "AWS_PROXY" : "HTTP_PROXY"
      uri  = each.value.integration_type == "Lambda" ?
              "arn:aws:apigateway:${var.region}:lambda:path/2015-03-31/functions/${each.value.backend_uri}/invocations" :
              each.value.backend_uri
      connection_type = each.value.integration_type == "Lambda" ? "INTERNET" : "VPC_LINK"
      connection_id   = each.value.integration_type == "Lambda" ? null :
                        aws_api_gateway_vpc_link.vpc_links[each.value.backend_uri].id
    }
  }
  depends_on = [aws_api_gateway_resource.resources]
}

/*-------------------------------------------------------------------------
   API Deployment and Stage
-------------------------------------------------------------------------*/
resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = var.stage_name
  description = "Deployment of ${var.api_name} to stage ${var.stage_name} in ${var.region}"

  // Force redeployment when endpoints change.
  triggers = {
    redeploy_trigger = sha1(jsonencode(var.endpoints))
  }
  depends_on = [aws_api_gateway_integration.integration]
}

/*-------------------------------------------------------------------------
   Usage Plan & API Key for MRAP
-------------------------------------------------------------------------*/
resource "aws_api_gateway_usage_plan" "usage_plan" {
  count = var.require_api_key ? 1 : 0
  name  = "${var.api_name}-usage-plan-${var.region}"
  description = "Usage plan for ${var.api_name} in ${var.region} with throttling"

  api_stages {
    api_id = aws_api_gateway_rest_api.api.id
    stage  = var.stage_name
  }

  throttle {
    rate_limit  = var.throttle_rate
    burst_limit = var.throttle_burst
  }
}

resource "aws_api_gateway_api_key" "api_key" {
  count       = var.require_api_key ? 1 : 0
  name        = "mrap-api-key"
  description = "MRAP API Key for ${var.api_name} in ${var.region}"
  enabled     = true
  // Optionally: set a predefined value using the "value" attribute.
}

resource "aws_api_gateway_usage_plan_key" "usage_plan_key" {
  count        = var.require_api_key ? 1 : 0
  key_id       = aws_api_gateway_api_key.api_key[0].id
  key_type     = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.usage_plan[0].id
}

/*-------------------------------------------------------------------------
   Outputs
-------------------------------------------------------------------------*/
output "invoke_url" {
  description = "The API Gateway invoke URL for ${var.api_name} in ${var.region}"
  value       = aws_api_gateway_rest_api.api.execution_invoke_url
}

