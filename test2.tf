# Load and decode the OpenAPI specification (YAML) into a Terraform map object
locals {
  openapi_spec = yamldecode(file("${path.module}/openapi.yaml"))
  paths        = try(local.openapi_spec.paths, {})  # all paths in the spec (or empty map if none)
}

# Define the set of recognized HTTP method keys (including the API Gateway ANY method extension)
locals {
  recognized_method_keys = [
    "get", "post", "put", "delete", "patch", "head", "options",
    "x-amazon-apigateway-any-method"
  ]
}

# Identify all path names, dynamic (proxy) paths, and methods defined for each path
locals {
  path_names    = sort(keys(local.paths))
  dynamic_paths = [for p in local.path_names : p if length(regexall("\\{[^}]+\\+\\}", p)) > 0]
  path_methods  = {
    for path, path_def in local.paths :
    path => [for k in keys(path_def) : k if k in local.recognized_method_keys]
  }
}

# Check for integration defined at the path level (outside specific methods)
locals {
  path_level_integration_types = {
    for path, path_def in local.paths :
    path => try(path_def["x-amazon-apigateway-integration"].type, null)
    if contains(keys(path_def), "x-amazon-apigateway-integration")
  }
}

# Check each method (including x-amazon-apigateway-any-method) for an integration and record its type
locals {
  method_integration_types = {
    for path, path_def in local.paths :
    path => {
      for method, method_def in path_def :
      method => try(method_def["x-amazon-apigateway-integration"].type, null)
      if method in local.recognized_method_keys
    }
  }
}

# Identify any methods missing an integration (type will be null if integration is absent or missing type)
locals {
  missing_integrations = flatten([
    for path, methods in local.method_integration_types :
    [
      for method, type in methods : "${path}:${method}"
      if type == null
    ]
  ])
  # Group missing integrations by path for more detailed info (if needed)
  missing_integrations_by_path = {
    for path, methods in local.method_integration_types :
    path => [for method, type in methods : method if type == null]
    if length([for method, type in methods : method if type == null]) > 0
  }
}

# Detect paths with no explicit method definitions (these should handle all HTTP methods by default)
locals {
  paths_without_methods = [
    for path, methods in local.path_methods : path 
    if length(methods) == 0
  ]
  # Among those, find any that also lack a path-level integration (meaning the path is completely unimplemented)
  paths_unimplemented = [
    for path in local.paths_without_methods : path 
    if contains(keys(local.path_level_integration_types), path) == false
  ]
}

# Determine the backend service type/category for each integration at the method level
locals {
  method_backend_service = {
    for path, methods in local.method_integration_types :
    path => {
      for method, type_val in methods :
      method => (
        (try(local.paths[path][method]["x-amazon-apigateway-integration"].connectionType, "") == "VPC_LINK") ? "VPC_LINK" :
        (lower(type_val) == "aws_proxy" ? "lambda" :
         lower(type_val) == "aws" ? (
           contains(try(local.paths[path][method]["x-amazon-apigateway-integration"].uri, ""), ":lambda:") ? "lambda" : "aws_service"
         ) :
         lower(type_val) == "http_proxy" ? "http_proxy" :
         lower(type_val) == "http" ? "http" :
         lower(type_val) == "mock" ? "mock" :
         "unknown"
        )
      )
      if type_val != null
    }
  }
  # (The above categorizes integration types: e.g., "aws_proxy" -> "lambda", 
  #  "aws" -> "lambda" (if URI indicates Lambda) or "aws_service", 
  #  "http"/"http_proxy" -> "VPC_LINK" if using a VPC link, otherwise "http"/"http_proxy", 
  #  "mock" -> "mock")
}

# Determine backend service type for any path-level integrations (if present)
locals {
  path_level_backend_service = {
    for path, type_val in local.path_level_integration_types :
    path => (
      (try(local.paths[path]["x-amazon-apigateway-integration"].connectionType, "") == "VPC_LINK") ? "VPC_LINK" :
      (lower(type_val) == "aws_proxy" ? "lambda" :
       lower(type_val) == "aws" ? (
         contains(try(local.paths[path]["x-amazon-apigateway-integration"].uri, ""), ":lambda:") ? "lambda" : "aws_service"
       ) :
       lower(type_val) == "http_proxy" ? "http_proxy" :
       lower(type_val) == "http" ? "http" :
       lower(type_val) == "mock" ? "mock" :
       "unknown"
      )
    )
  }
}

# Validation flags (booleans) that can be used in precondition checks or resource counts
locals {
  all_methods_have_integrations = length(local.missing_integrations) == 0    # True if every defined method has an integration
  all_paths_implemented         = length(local.paths_unimplemented) == 0    # True if every path is implemented (has methods or a direct integration)
}

# (The above locals can be used in `precondition` blocks or conditional `count` logic to enforce the OpenAPI spec validity.
#  For example, a precondition could assert `local.all_methods_have_integrations` and `local.all_paths_implemented` are true,
#  using `local.missing_integrations` and `local.paths_unimplemented` for detailed error messages if needed.)
