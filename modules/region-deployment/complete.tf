# File structure:
# .
# ├── main.tf
# ├── variables.tf
# ├── outputs.tf
# ├── api-config.yaml
# └── modules/
#     └── member-zone/
#         ├── main.tf
#         ├── variables.tf
#         └── outputs.tf

# api-config.yaml
name: "mrap-api"
regions: ["us-east-1", "us-east-2"]
stage_name: "prod"
private_api: true

resources:
  - path: "ec2-service"
    methods:
      - http_method: "GET"
        integration_type: "HTTP_PROXY"
        uri: "http://nlb_dns_placeholder/ec2"
        request_validator: "ALL"
        throttling:
          rate_limit: 100
          burst_limit: 50

  - path: "lambda-process"
    methods:
      - http_method: "POST"
        integration_type: "AWS_PROXY"
        uri: "arn:aws:apigateway:${region}:lambda:path/2015-03-31/functions/${lambda_arn}/invocations"
        throttling:
          rate_limit: 200
          burst_limit: 100

  - path: "static"
    methods:
      - http_method: "GET"
        integration_type: "S3_PROXY"
        uri: "arn:aws:apigateway:${region}:s3:path/{bucket}/{key}"
        request_parameters:
          "integration.request.path.bucket": "'static-content'"
          "integration.request.path.key": "method.request.path.proxy"

models: {}


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
  alias  = "us_east_1"
  region = "us-east-1"
}

provider "aws" {
  alias  = "us_east_2"
  region = "us-east-2"
}

module "member_zone_use1" {
  source    = "./modules/member-zone"
  providers = {
    aws = aws.us_east_1
  }

  api_config          = local.config
  existing_vpc_id     = "vpc-12345678"  # Member zone VPC ID
  existing_subnet_ids = ["subnet-12345", "subnet-67890"] 
  route53_zone_name   = "member.example.com"
  region              = "us-east-1"
}

module "member_zone_use2" {
  source    = "./modules/member-zone"
  providers = {
    aws = aws.us_east_2
  }

  api_config          = local.config
  existing_vpc_id     = "vpc-abcdefgh"  # Member zone VPC ID
  existing_subnet_ids = ["subnet-abcde", "subnet-fghij"]
  route53_zone_name   = "member.example.com"
  region              = "us-east-2"
}


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
variable "route53_zone_name" {}
variable "region" {}

data "aws_vpc" "member" {
  id = var.existing_vpc_id
}

data "aws_subnets" "private" {
  filter {
    name   = "subnet-id"
    values = var.existing_subnet_ids
  }
}

# MRAP API Gateway
resource "aws_apigatewayv2_api" "mrap" {
  name          = var.api_config.name
  protocol_type = "HTTP"
  description   = "Member Zone MRAP API Gateway"
  disable_execute_api_endpoint = var.api_config.private_api
  
  tags = {
    Environment = var.api_config.stage_name
  }
}

# VPC Link for NLB Integration
resource "aws_apigatewayv2_vpc_link" "nlb_link" {
  name               = "${var.api_config.name}-vpc-link"
  security_group_ids = [aws_security_group.api_gw.id]
  subnet_ids         = var.existing_subnet_ids
}

# Network Load Balancer
resource "aws_lb" "backend_nlb" {
  name               = "${var.api_config.name}-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.existing_subnet_ids

  enable_deletion_protection = true
}

# NLB Listener and Target Group
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.backend_nlb.arn
  port              = 443
  protocol          = "TLS"
  certificate_arn   = aws_acm_certificate.api.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2.arn
  }
}

resource "aws_lb_target_group" "ec2" {
  name        = "${var.api_config.name}-ec2-tg"
  port        = 80
  protocol    = "TCP"
  vpc_id      = var.existing_vpc_id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
    interval = 30
  }
}

# EC2 Auto Scaling Group
resource "aws_launch_template" "ec2" {
  name_prefix   = "${var.api_config.name}-ec2-"
  image_id      = "ami-12345678"  # Update with your AMI
  instance_type = "t3.micro"
  
  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.ec2.id]
  }
}

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

# Lambda Function
resource "aws_lambda_function" "processor" {
  function_name = "${var.api_config.name}-processor"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.handler"
  runtime       = "python3.9"
  filename      = "${path.module}/lambda/function.zip"

  vpc_config {
    subnet_ids         = var.existing_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }
}

# S3 Static Website
resource "aws_s3_bucket" "static" {
  bucket = "${var.api_config.name}-static-content"
  acl    = "private"

  website {
    index_document = "index.html"
    error_document = "error.html"
  }
}

# API Gateway Integrations
resource "aws_apigatewayv2_integration" "nlb" {
  api_id           = aws_apigatewayv2_api.mrap.id
  integration_type = "HTTP_PROXY"
  integration_uri  = "http://${aws_lb.backend_nlb.dns_name}/{proxy}"
  connection_type  = "VPC_LINK"
  connection_id    = aws_apigatewayv2_vpc_link.nlb_link.id
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id           = aws_apigatewayv2_api.mrap.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.processor.invoke_arn
}

# Route53 & ACM Configuration
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

resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.private.zone_id
  name    = "api.${var.route53_zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [aws_apigatewayv2_api.mrap.api_endpoint]
}

# Security Groups
resource "aws_security_group" "api_gw" {
  name        = "${var.api_config.name}-api-sg"
  description = "Security group for API Gateway VPC Link"
  vpc_id      = var.existing_vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # Core zone CIDR
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ec2" {
  name        = "${var.api_config.name}-ec2-sg"
  description = "Security group for EC2 instances"
  vpc_id      = var.existing_vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [aws_security_group.api_gw.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM Roles
resource "aws_iam_role" "lambda_exec" {
  name = "${var.api_config.name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Outputs
output "api_endpoints" {
  value = {
    us_east_1 = module.member_zone_use1.api_endpoint
    us_east_2 = module.member_zone_use2.api_endpoint
  }
}

output "api_keys" {
  value = {
    us_east_1 = module.member_zone_use1.api_key
    us_east_2 = module.member_zone_use2.api_key
  }
  sensitive = true
}


# modules/member-zone/variables.tf
variable "api_config" {
  description = "API Gateway configuration"
  type = object({
    name        = string
    regions     = list(string)
    stage_name  = string
    private_api = bool
    resources   = list(any)
    models      = map(any)
  })
}

variable "existing_vpc_id" {
  description = "Existing VPC ID for member zone"
  type        = string
}

variable "existing_subnet_ids" {
  description = "Existing private subnet IDs"
  type        = list(string)
}

variable "route53_zone_name" {
  description = "Route53 private zone name"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}



# modules/member-zone/outputs.tf
output "api_endpoint" {
  value = aws_apigatewayv2_api.mrap.api_endpoint
}

output "api_key" {
  value     = aws_apigatewayv2_api_key.mrap_key.value
  sensitive = true
}

output "nlb_dns" {
  value = aws_lb.backend_nlb.dns_name
}

output "lambda_arn" {
  value = aws_lambda_function.processor.arn
}

