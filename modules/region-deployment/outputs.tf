output "invoke_url" {
  value       = aws_api_gateway_rest_api.api.execution_invoke_url
  description = "Invoke URL for API in this region"
}
