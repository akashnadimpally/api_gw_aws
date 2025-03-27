variable "region"         { type = string }
variable "api_name"       { type = string }
variable "stage_name"     { type = string }
variable "endpoints"      { type = list(map(string)) }
variable "require_api_key"{ type = bool }
variable "throttle_rate"  { type = number }
variable "throttle_burst" { type = number }
