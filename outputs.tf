output "api_invoke_urls" {
  description = "Invoke URLs for the API in each region"
  value = { for region, mod in module.api_deployments : region => mod.invoke_url }
}
