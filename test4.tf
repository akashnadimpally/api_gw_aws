terraform {
  required_version = ">= 1.7.4"
}

locals {
  # Parse the OpenAPI YAML file into a Terraform map/object
  openapi_spec = yamldecode(file("${path.module}/specs/openapispec_apikey.yaml"))  :contentReference[oaicite:5]{index=5}

  # Allowed HTTP methods for operations (as lowercase, per OpenAPI spec)
  allowed_methods = ["get", "post", "put", "delete", "patch", "head", "options"]
  ext_any        = "x-amazon-apigateway-any-method"  # AWS extension for catch-all method
  allowed_ops_keys = concat(local.allowed_methods, [local.ext_any])  # recognized operation keys

  # Global spec-level validations
  openapi_version       = try(local.openapi_spec["openapi"], "")                     # OpenAPI version string or "" if missing
  openapi_version_valid = local.openapi_version != "" && startswith(local.openapi_version, "3.")  # Must start with "3."
  paths                 = try(local.openapi_spec["paths"], {})                       # paths map (empty if none)
  has_paths             = length(keys(local.paths)) > 0                              # At least one path defined
  info_title_ok         = try(local.openapi_spec.info.title, "") != ""               # Info.title exists and not empty
  info_version_ok       = try(local.openapi_spec.info.version, "") != ""             # Info.version exists and not empty

  # Endpoint configuration type must be PRIVATE: check for VPC endpoint IDs in the servers configuration (AWS extension)
  endpoint_private_valid = can(local.openapi_spec["servers"]) && length(local.openapi_spec["servers"]) > 0 && length([
    for s in local.openapi_spec["servers"] : s
    if can(s["x-amazon-apigateway-endpoint-configuration"]) &&
       can(s["x-amazon-apigateway-endpoint-configuration"].vpcEndpointIds) &&
       length(s["x-amazon-apigateway-endpoint-configuration"].vpcEndpointIds) > 0
  ]) > 0

  # Stage must be 'dev': check the first server's URL or variables for 'dev'
  stage_dev_valid = can(local.openapi_spec["servers"]) && length(local.openapi_spec["servers"]) > 0 && (
    ( can(local.openapi_spec.servers[0].variables) && (
        (can(local.openapi_spec.servers[0].variables.stage)    && local.openapi_spec.servers[0].variables.stage.default == "dev") ||
        (can(local.openapi_spec.servers[0].variables.basePath) && trim(local.openapi_spec.servers[0].variables.basePath.default, "/") == "dev")
      )
    ) ||
    (can(local.openapi_spec.servers[0].url) && local.openapi_spec.servers[0].url =~ "/dev($|/)")
  )

  # === Collect validation errors ===

  # 1. General spec errors (version, info, stage, endpoint config, paths)
  general_errors = concat(
    local.openapi_version_valid ? [] : ["OpenAPI spec must use version 3.x (found ${local.openapi_version})"],
    local.has_paths             ? [] : ["No paths defined in OpenAPI specification"],
    local.info_title_ok         ? [] : ["Info.title is missing or empty"],
    local.info_version_ok       ? [] : ["Info.version is missing or empty"],
    local.stage_dev_valid       ? [] : ["API stage must be set to 'dev'"],
    local.endpoint_private_valid ? [] : ["Endpoint configuration type must be PRIVATE"]
  )

  # 2. Unrecognized HTTP methods (operations must use standard verbs)
  verb_errors = flatten([
    for path, ops in local.paths : [
      for method, op in ops : "Unrecognized HTTP verb '${method}' in path ${path}"
      if !(method in local.allowed_methods || method == local.ext_any || method == "parameters" || method == "summary" || method == "description" || method == "servers")
    ]
  ])

  # 3. Missing operation summary
  summary_errors = flatten([
    for path, ops in local.paths : [
      for method, op in ops : "Missing summary for ${method} ${path}"
      if method in local.allowed_ops_keys && try(op.summary, "") == ""
    ]
  ])

  # 4. Response code validations for each operation
  response_2xx_errors = flatten([
    for path, ops in local.paths : [
      for method, op in ops : "No 2xx response defined for ${method} ${path}"
      if method in local.allowed_ops_keys && length([
           for code in keys(try(op.responses, {})) : code
           if can(tonumber(code)) && tonumber(code) >= 200 && tonumber(code) < 300
         ]) == 0
    ]
  ])
  response_4xx_errors = flatten([
    for path, ops in local.paths : [
      for method, op in ops : "No 4xx response defined for ${method} ${path}"
      if method in local.allowed_ops_keys && length([
           for code in keys(try(op.responses, {})) : code
           if can(tonumber(code)) && tonumber(code) >= 400 && tonumber(code) < 500
         ]) == 0
    ]
  ])
  response_5xx_errors = flatten([
    for path, ops in local.paths : [
      for method, op in ops : "No 5xx response defined for ${method} ${path}"
      if method in local.allowed_ops_keys && length([
           for code in keys(try(op.responses, {})) : code
           if can(tonumber(code)) && tonumber(code) >= 500 && tonumber(code) < 600
         ]) == 0
    ]
  ])

  # 5. API integration check: every operation must have a valid x-amazon-apigateway-integration
  integration_missing_errors = flatten([
    for path, ops in local.paths : [
      for method, op in ops : "No integration defined for ${method} ${path}"
      if method in local.allowed_ops_keys && try(op["x-amazon-apigateway-integration"], null) == null
    ]
  ])
  integration_type_errors = flatten([
    for path, ops in local.paths : [
      for method, op in ops : "Unrecognized integration type '${try(op["x-amazon-apigateway-integration"].type, "unknown")}' for ${method} ${path}"
      if method in local.allowed_ops_keys &&
         try(op["x-amazon-apigateway-integration"], null) != null &&
         !contains(["AWS", "AWS_PROXY", "HTTP", "HTTP_PROXY", "MOCK"], try(op["x-amazon-apigateway-integration"].type, ""))
    ]
  ])

  # 6. Usage plan validations (throttle and quota fields)
  usage_plans_raw  = try(local.openapi_spec["x-amazon-apigateway-usage-plans"], [])
  usage_plans_list = local.usage_plans_raw == null ? [] :
                     (can(keys(local.usage_plans_raw)) ? [local.usage_plans_raw] : local.usage_plans_raw)
  usage_plan_errors = flatten([
    for idx, up in local.usage_plans_list : concat(
      # Ensure throttle.rateLimit and throttle.burstLimit are present
      (!(can(up.throttle) && can(up.throttle.rateLimit) && up.throttle.rateLimit != null) ? 
         ["Usage plan '${try(up.name, "index "+tostring(idx))}' missing rateLimit"] : []),
      (!(can(up.throttle) && can(up.throttle.burstLimit) && up.throttle.burstLimit != null) ? 
         ["Usage plan '${try(up.name, "index "+tostring(idx))}' missing burstLimit"] : []),
      # Ensure quota.limit and quota.period are present
      (!(can(up.quota) && can(up.quota.limit) && up.quota.limit != null) ? 
         ["Usage plan '${try(up.name, "index "+tostring(idx))}' missing quota.limit"] : []),
      (!(can(up.quota) && can(up.quota.period) && up.quota.period != null) ? 
         ["Usage plan '${try(up.name, "index "+tostring(idx))}' missing quota.period"] : []),
      # Ensure quota.period is one of the allowed values (MONTH, WEEK, DAY)
      ((can(up.quota) && can(up.quota.period) && up.quota.period != null && !contains(["MONTH","WEEK","DAY"], up.quota.period)) ? 
         ["Usage plan '${try(up.name, "index "+tostring(idx))}' has invalid quota.period '${up.quota.period}' (allowed: MONTH, WEEK, DAY)"] : [])
    )
  ])

  # Combine all error lists into one (flattened) list
  openapi_error_list = [
    for e in concat(
      local.general_errors,
      local.verb_errors,
      local.summary_errors,
      local.response_2xx_errors,
      local.response_4xx_errors,
      local.response_5xx_errors,
      local.integration_missing_errors,
      local.integration_type_errors,
      local.usage_plan_errors
    ) : e
  ]

  # Integration summary: map each path and method to the determined backend type
  api_paths_integration_summary = {
    for path, ops in local.paths : 
      path => {
        for method, op in ops :
          method => (
            can(op["x-amazon-apigateway-integration"]) ? (
              # Determine backend type from integration details
              (can(op["x-amazon-apigateway-integration"].connectionType) && op["x-amazon-apigateway-integration"].connectionType == "VPC_LINK") ? "vpc_link" :
              contains(["AWS", "AWS_PROXY"], try(op["x-amazon-apigateway-integration"].type, "")) ? (
                contains(lower(try(op["x-amazon-apigateway-integration"].uri, "")), "lambda") ? "lambda" : "aws_service"
              ) :
              (try(op["x-amazon-apigateway-integration"].type, "") == "HTTP_PROXY" ? "http_proxy" :
               try(op["x-amazon-apigateway-integration"].type, "") == "HTTP"       ? "http" :
               try(op["x-amazon-apigateway-integration"].type, "") == "MOCK"       ? "mock" : "unknown")
            ) : "unknown"
          )
        if method in local.allowed_ops_keys  # include only actual operations (skip path-level keys)
      }
  }
}

# Output whether the OpenAPI spec passed all semantic checks (true if no errors)
output "openapi_semantic_ok" {
  value = length(local.openapi_error_list) == 0
}

# Output the list of all semantic errors found (empty if none)
output "openapi_error_list" {
  value = local.openapi_error_list
}

# Output a summary of each path/method mapped to its integration backend type
output "api_paths_integration_summary" {
  value = local.api_paths_integration_summary
}
