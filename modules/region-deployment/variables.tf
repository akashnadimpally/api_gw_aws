variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the main VPC"
}

variable "private_subnets" {
  type        = list(string)
  description = "List of private subnet CIDR blocks"
}

variable "aws_region" {
  type        = string
  description = "AWS region for resources"
}

variable "api_config" {
  type = object({
    name        = string
    stage_name  = string
    description = optional(string)
    resources = list(object({
      path    = string
      methods = list(object({
        http_method        = string
        integration_type   = string
        uri                = string
        request_validator  = optional(string)
        request_model      = optional(string)
        throttling = optional(object({
          rate_limit  = number
          burst_limit = number
        }))
      }))
    }))
  })
  description = "API Gateway configuration from YAML"
}

variable "throttling_rate_limit" {
  type        = number
  default     = 1000
  description = "Default requests per second limit"
}

variable "throttling_burst_limit" {
  type        = number
  default     = 500
  description = "Default burst capacity limit"
}

variable "nlb_enable_deletion_protection" {
  type        = bool
  default     = true
  description = "Enable deletion protection for NLB"
}

variable "vpc_endpoint_security_group_ids" {
  type        = list(string)
  default     = []
  description = "Additional security groups for VPC Endpoint"
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  default     = ["10.0.0.0/16"]
  description = "CIDR blocks allowed to access VPC Endpoint"
}

variable "enable_private_dns" {
  type        = bool
  default     = true
  description = "Enable private DNS for VPC Endpoint"
}

variable "api_gateway_policy" {
  type        = string
  default     = ""
  description = "Custom API Gateway resource policy"
}

variable "vpc_link_name" {
  type        = string
  default     = "api-nlb-link"
  description = "Name for the API Gateway VPC Link"
}

variable "lambda_source_path" {
  type        = string
  default     = "lambda/data-processor.zip"
  description = "Path to Lambda function source code"
}


variable "organization_id" {
  type = string
  description = "ORG ID"
}
