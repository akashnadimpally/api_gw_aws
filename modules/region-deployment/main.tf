terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  api_methods = flatten([
    for resource in var.api_config.resources : [
      for method in resource.methods : {
        resource_path    = resource.path
        http_method      = method.http_method
        integration_type = method.integration_type
        auth_type        = method.auth_type
        uri              = method.uri
      }
    ]
  ])
}

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  enable_dns_support = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
}

resource "aws_lb" "internal" {
  name               = "api-internal-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = aws_subnet.private.*.id

  enable_deletion_protection = false
}

resource "aws_vpc_endpoint" "api_gw" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.execute-api"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private.*.id
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
}

resource "aws_api_gateway_rest_api" "private" {
  name        = var.api_config.name
  description = "Private API Gateway"
  endpoint_configuration {
    types = ["PRIVATE"]
  }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Deny"
        Principal = "*"
        Action = "execute-api:Invoke"
        Resource = "execute-api:/*/*/*"
        Condition = {
          StringNotEquals = {
            "aws:SourceVpce" = aws_vpc_endpoint.api_gw.id,
            "aws:PrincipalOrgID" = var.organization_id
          },
          ArgNotLike = {
            "aws:PrincipalArn" = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*"]
          }
        }
      },
      {
        Effect = "Allow"
        Principal = "*"
        Action = "execute-api:Invoke"
        Resource = "execute-api:/*/*/*",
        Condition = {
            StringEquals = {
                "aws.SourceVpce" = aws_vpc_endpoint.api_gw.id
            },
            ArnLike = {
                "aws:PrincipalArn" = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*"]
            }
        }
      }
    ]
  })
}

resource "aws_api_gateway_resource" "resource" {
  for_each    = { for r in var.api_config.resources : r.path => r }
  rest_api_id = aws_api_gateway_rest_api.private.id
  parent_id   = aws_api_gateway_rest_api.private.root_resource_id
  path_part   = each.value.path
}

resource "aws_api_gateway_method" "method" {
  for_each = { 
    for method in local.api_methods : 
    "${method.resource_path}-${method.http_method}" => method 
  }

  rest_api_id   = aws_api_gateway_rest_api.private.id
  resource_id   = aws_api_gateway_resource.resource[each.value.resource_path].id
  http_method   = each.value.http_method
  
  authorization = lookup({
    "CUSTOM"   = "CUSTOM"
    "COGNITO"  = "COGNITO_USER_POOLS"
    "NONE"     = "NONE"
  }, each.value.auth_type, "NONE")

  authorizer_id = lookup({
    "CUSTOM"   = aws_api_gateway_authorizer.custom.id
    "COGNITO"  = aws_api_gateway_authorizer.cognito.id
  }, each.value.auth_type, null)

  request_validator_id = aws_api_gateway_request_validator.main.id
  request_models       = { 
    "application/json" = "Empty" 
  }
}

resource "aws_api_gateway_integration" "integration" {
  for_each = aws_api_gateway_method.method

  rest_api_id = aws_api_gateway_rest_api.private.id
  resource_id = each.value.resource_id
  http_method = each.value.http_method

  # Get configuration from original method definition
  type = local.api_methods[index(
    [for m in local.api_methods : "${m.resource_path}-${m.http_method}"],
    each.key
  )].integration_type

  integration_http_method = local.api_methods[index(
    [for m in local.api_methods : "${m.resource_path}-${m.http_method}"],
    each.key
  )].integration_type == "AWS_PROXY" ? "POST" : "ANY"

  uri = local.api_methods[index(
    [for m in local.api_methods : "${m.resource_path}-${m.http_method}"],
    each.key
  )].integration_type == "AWS_PROXY" ? aws_lambda_function.data_processor.invoke_arn : replace(
    local.api_methods[index(
      [for m in local.api_methods : "${m.resource_path}-${m.http_method}"],
      each.key
    )].uri,
    "nlb_dns_placeholder",
    aws_lb.internal.dns_name
  )

  connection_type = local.api_methods[index(
    [for m in local.api_methods : "${m.resource_path}-${m.http_method}"],
    each.key
  )].integration_type == "HTTP_PROXY" ? "VPC_LINK" : "INTERNET"

  connection_id = local.api_methods[index(
    [for m in local.api_methods : "${m.resource_path}-${m.http_method}"],
    each.key
  )].integration_type == "HTTP_PROXY" ? aws_api_gateway_vpc_link.main.id : null
}

resource "aws_api_gateway_vpc_link" "main" {
  name        = "api-nlb-link"
  target_arns = [aws_lb.internal.arn]
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.private.id
#   stage_name = var.api_config.stage_name

  depends_on = [
    aws_api_gateway_method.method,
    aws_api_gateway_integration.integration
  ]
}

resource "aws_api_gateway_stage" "stage" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.private.id
  stage_name    = var.api_config.stage_name
}

resource "aws_api_gateway_request_validator" "main" {
  rest_api_id     = aws_api_gateway_rest_api.private.id
  name            = "body-validator"
  validate_request_body   = true
  validate_request_parameters = true
}

resource "aws_api_gateway_usage_plan" "main" {
  name = "api-usage-plan"

  # In aws_api_gateway_usage_plan resource:
throttle_settings {
  rate_limit  = var.throttling_rate_limit
  burst_limit = var.throttling_burst_limit
}

  api_stages {
    api_id = aws_api_gateway_rest_api.private.id
    stage  = aws_api_gateway_stage.stage.stage_name
  }
}

resource "aws_security_group" "vpc_endpoint" {
  name        = "api-gw-endpoint-sg"
  description = "Security group for VPC Endpoint"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}



# resource "aws_vpc_endpoint" "api_gw" {
#   vpc_id              = aws_vpc.main.id
#   service_name        = aws_api_gateway_rest_api.private.id
#   vpc_endpoint_type   = "Interface"
#   security_group_ids  = [aws_security_group.vpc_endpoint.id]
#   subnet_ids          = aws_subnet.private.*.id
#   private_dns_enabled = true
# }
