variable "environment" {
  type    = string
  default = "dev"
}

variable "trusted_roles" {
  type    = list(string)
  default = []
}

variable "openapi_spec" {
  type    = string
  default = "specs/simpleopenapispec.yaml"
}

variable "quota_offset" {
  type    = number
  default = 0
}

variable "app_name" {
  type    = string
  default = "skynetalpha"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "protect_ou_env" {
  type    = bool
  default = true
}