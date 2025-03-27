# modules/member-zone/main.tf
variable "api_config" {
  type = object({
    name        = string
    regions     = list(string)
    stage_name  = string
    private_api = bool
    resources   = list(any)
    models      = map(any)
  })
}

variable "existing_vpc_id" {}
variable "existing_subnet_ids" {}
variable "existing_vpce_ids" {}
variable "route53_zone_name" {}
variable "region" {}

# REST API Gateway
resource "aws_api_gateway_rest_api" "main" {
  name        = var.api_config.name
  description = "Member Zone Private API"
  
  endpoint_configuration {
    types = ["PRIVATE"]
  }

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Deny",
      Principal = "*",
      Action = "execute-api:Invoke",
      Resource = "execute-api:/*/*/*",
      Condition = {
        StringNotEquals = {
          "aws:SourceVpce" = var.existing_vpce_ids
        }
      }
    },{
      Effect = "Allow",
      Principal = "*",
      Action = "execute-api:Invoke",
      Resource = "execute-api:/*/*/*"
    }]
  })
}

# NLB Configuration
resource "aws_lb" "backend" {
  name               = "${var.api_config.name}-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.existing_subnet_ids
}

resource "aws_lb_target_group" "ec2" {
  name     = "${var.api_config.name}-ec2-tg"
  port     = 80
  protocol = "TCP"
  vpc_id   = var.existing_vpc_id

  health_check {
    protocol = "TCP"
    interval = 30
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.backend.arn
  port              = 443
  protocol          = "TLS"
  certificate_arn   = aws_acm_certificate.api.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2.arn
  }
}

# VPC Link
resource "aws_api_gateway_vpc_link" "nlb_link" {
  name        = "${var.api_config.name}-vpc-link"
  target_arns = [aws_lb.backend.arn]
}

# Lambda Function
resource "aws_lambda_function" "processor" {
  function_name = "${var.api_config.name}-processor"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.handler"
  runtime       = "python3.9"
  filename      = "${path.module}/lambda/function.zip"
}

# API Resources and Methods
resource "aws_api_gateway_resource" "resource" {
  for_each    = { for r in var.api_config.resources : r.path => r }
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = each.value.path
}

resource "aws_api_gateway_method" "method" {
  for_each = { 
    for method in local.all_methods : 
    "${method.resource_path}_${method.http_method}" => method 
  }

  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.resource[each.value.resource_path].id
  http_method   = each.value.http_method
  authorization = "NONE"
  api_key_required = true

  request_validator_id = each.value.request_validator != null ? 
    aws_api_gateway_request_validator.main.id : null
}

# Integrations
resource "aws_api_gateway_integration" "nlb" {
  for_each = { 
    for method in local.all_methods : 
    "${method.resource_path}_${method.http_method}" => method 
    if method.integration_type == "HTTP_PROXY"
  }

  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.resource[each.value.resource_path].id
  http_method             = each.value.http_method
  type                    = "HTTP_PROXY"
  uri                     = replace(each.value.uri, "nlb_dns_placeholder", aws_lb.backend.dns_name)
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.nlb_link.id
}

resource "aws_api_gateway_integration" "lambda" {
  for_each = { 
    for method in local.all_methods : 
    "${method.resource_path}_${method.http_method}" => method 
    if method.integration_type == "AWS_PROXY"
  }

  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.resource[each.value.resource_path].id
  http_method             = each.value.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = each.value.uri
}

# Request Validator
resource "aws_api_gateway_request_validator" "main" {
  name                  = "body-validator"
  rest_api_id           = aws_api_gateway_rest_api.main.id
  validate_request_body = true
}

# Usage Plan and API Key
resource "aws_api_gateway_usage_plan" "main" {
  name = "${var.api_config.name}-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.main.id
    stage  = aws_api_gateway_stage.main.stage_name
  }

  throttle_settings {
    rate_limit  = 1000
    burst_limit = 500
  }
}

resource "aws_api_gateway_api_key" "main" {
  name = "mrap-api-key"
}

resource "aws_api_gateway_usage_plan_key" "main" {
  key_id        = aws_api_gateway_api_key.main.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.main.id
}

# Certificate Management
resource "aws_acm_certificate" "api" {
  domain_name       = "api.${var.route53_zone_name}"
  validation_method = "DNS"
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.api.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.private.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 300
  records = [each.value.record]
}

# Outputs
output "api_endpoint" {
  value = aws_api_gateway_deployment.main.invoke_url
}

output "api_key" {
  value     = aws_api_gateway_api_key.main.value
  sensitive = true
}

# Auto Scaling Group
resource "aws_autoscaling_group" "ec2" {
  name                = "${var.api_config.name}-asg"
  min_size            = 2
  max_size            = 4
  desired_capacity    = 2
  vpc_zone_identifier = var.existing_subnet_ids

  launch_template {
    id      = aws_launch_template.ec2.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.ec2.arn]
}

locals {
  all_methods = flatten([
    for resource in var.api_config.resources : [
      for method in resource.methods : merge(method, {
        resource_path = resource.path
      })
    ]
  ])
}
