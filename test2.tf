Thanks. I’ll now generate a fully consolidated `semantic_check.tf` file that:

- Validates your OpenAPI YAML spec end-to-end.
- Includes a `fileexists()` check to enforce presence.
- Checks that the file is structurally and semantically valid for `aws_api_gateway_rest_api.body`.
- Outputs validation booleans and detailed integration summaries by path/method.

I'll let you know as soon as it’s ready for review.

# Terraform OpenAPI Semantic Validation

The following Terraform configuration (`semantic_check.tf`) performs a comprehensive validation of an OpenAPI YAML specification for AWS API Gateway. It uses `yamldecode` to parse the file and checks for required structural elements (version, info, paths, etc.), validates each API path and method integration (including support for nested and wildcard paths like `/health` or `/{proxy+}`), and categorizes integrations by backend type (e.g. Lambda, ECS via VPC Link, HTTP proxy). 

All checks run at **plan time**. A `null_resource` with preconditions will **fail the plan** if any validation errors are found, listing all issues. Additionally, output values summarize the results:
- `openapi_spec_valid` – a boolean flag indicating if the spec is structurally compatible with `aws_api_gateway_rest_api.body`.
- `api_paths_integration_summary` – a list summarizing each path, method, and the identified integration backend type.

```hcl
terraform {
  # Ensure we use at least Terraform 1.3+ for precondition support
  required_version = ">= 1.3.0"
}

variable "openapi_spec_path" {
  description = "Path to the OpenAPI spec (YAML) file to validate"
  type        = string
}

locals {
  # Check if the spec file exists
  spec_file_exists = fileexists(var.openapi_spec_path)

  # Parse the YAML file into an object (empty if file missing to allow further checks)
  spec_raw = local.spec_file_exists ? yamldecode(file(var.openapi_spec_path)) : {}

  # Determine OpenAPI/Swagger version string
  openapi_version = can(local.spec_raw.openapi) && local.spec_raw.openapi != null ? tostring(local.spec_raw.openapi) :
                    can(local.spec_raw.swagger) && local.spec_raw.swagger != null ? tostring(local.spec_raw.swagger) : ""

  # Validate version: must be OpenAPI 3.0.x or Swagger 2.0 (AWS API Gateway supports these)
  version_valid = local.openapi_version != "" && (
                    startswith(local.openapi_version, "3.0.") ||
                    local.openapi_version == "2.0"
                  )

  # Validate required API info fields
  info_valid  = can(local.spec_raw.info) && local.spec_raw.info.title != null && local.spec_raw.info.version != null

  # Validate that at least one path is defined
  paths_valid = can(local.spec_raw.paths) && length(keys(local.spec_raw.paths)) > 0

  # Validate usage plan definitions if present (x-amazon-apigateway-usage-plans)
  usage_plans       = can(local.spec_raw["x-amazon-apigateway-usage-plans"]) ? local.spec_raw["x-amazon-apigateway-usage-plans"] : []
  usage_plan_errors = flatten([
    for up in local.usage_plans : concat(
      up.name == null ? ["Usage plan missing name"] : [],
      (can(up.throttle) && (up.throttle.rateLimit == null || up.throttle.burstLimit == null)) ? 
        ["Usage plan ${lookup(up, "name", "unnamed")} has incomplete throttle settings"] : [],
      (can(up.quota) && (up.quota.limit == null || up.quota.period == null)) ? 
        ["Usage plan ${lookup(up, "name", "unnamed")} has incomplete quota settings"] : []
    )
  ])
  usage_plans_valid = length(local.usage_plan_errors) == 0

  # Validate each path and method
  # Check for integration presence and correctness, and ensure responses are defined.
  # Supports standard methods and the x-amazon-apigateway-any-method for wildcards.
  operation_errors = flatten([
    for path, path_item in local.spec_raw.paths : [
      # Iterate over each operation in the path
      for method, operation in path_item :
      # Only consider actual HTTP methods and the ANY-method (skip path-level parameters or other extensions)
      (method == "parameters" || (startswith(method, "x-") && method != "x-amazon-apigateway-any-method")) ? [] :
      concat(
        # 1. Check integration presence
        (! can(operation["x-amazon-apigateway-integration"]) ? 
          ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: missing x-amazon-apigateway-integration"] : 
          []),

        # 2. If integration exists, validate required fields and values
        can(operation["x-amazon-apigateway-integration"]) ? concat(
          # Allowed integration types (aws, aws_proxy, http, http_proxy, mock) ([x-amazon-apigateway-integration object - Amazon API Gateway](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-swagger-extensions-integration.html#:~:text=The%20type%20of%20integration%20with,Valid%20values%20are))
          (contains(["aws","aws_proxy","http","http_proxy","mock"], operation["x-amazon-apigateway-integration"].type) ? [] :
            ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: invalid integration type '${operation["x-amazon-apigateway-integration"].type}'"]),
          # HTTP integrations must have a URI starting with http:// or https://
          ((operation["x-amazon-apigateway-integration"].type == "http" || operation["x-amazon-apigateway-integration"].type == "http_proxy") && 
            (operation["x-amazon-apigateway-integration"].uri == null || ! can(regex("^https?://", operation["x-amazon-apigateway-integration"].uri)))) ?
            ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: HTTP integration missing or invalid URI"] : [],
          # If using VPC Link, connectionId must be provided
          ((operation["x-amazon-apigateway-integration"].type == "http" || operation["x-amazon-apigateway-integration"].type == "http_proxy") &&
            lower(try(operation["x-amazon-apigateway-integration"].connectionType, "")) == "vpc_link" &&
            operation["x-amazon-apigateway-integration"].connectionId == null) ?
            ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: VPC_LINK integration missing connectionId"] : [],
          # AWS integrations must have an ARN URI
          ((operation["x-amazon-apigateway-integration"].type == "aws" || operation["x-amazon-apigateway-integration"].type == "aws_proxy") &&
            (operation["x-amazon-apigateway-integration"].uri == null || !startswith(operation["x-amazon-apigateway-integration"].uri, "arn:"))) ?
            ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: AWS integration missing or invalid URI (must be ARN)"] : [],
          # AWS integrations must specify an integration HTTP method
          ((operation["x-amazon-apigateway-integration"].type == "aws" || operation["x-amazon-apigateway-integration"].type == "aws_proxy") &&
            operation["x-amazon-apigateway-integration"].httpMethod == null) ?
            ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: AWS integration missing httpMethod"] : [],
          # If Lambda proxy integration, httpMethod must be POST ([x-amazon-apigateway-integration object - Amazon API Gateway](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-swagger-extensions-integration.html#:~:text=,POST))
          (operation["x-amazon-apigateway-integration"].type == "aws_proxy" &&
            can(operation["x-amazon-apigateway-integration"].uri) && can(regex("lambda:path", operation["x-amazon-apigateway-integration"].uri)) &&
            operation["x-amazon-apigateway-integration"].httpMethod != "POST") ?
            ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: Lambda proxy integration must use HTTP POST"] : [],
          # If Lambda integration (non-proxy), ensure credentials (IAM role) are provided to authorize API Gateway to invoke
          (operation["x-amazon-apigateway-integration"].type == "aws" &&
            can(operation["x-amazon-apigateway-integration"].uri) && can(regex("lambda:", operation["x-amazon-apigateway-integration"].uri)) &&
            operation["x-amazon-apigateway-integration"].credentials == null) ?
            ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: Lambda integration missing IAM credentials"] : [],
          # aws_proxy should only target Lambda (URI containing 'lambda:path')
          (operation["x-amazon-apigateway-integration"].type == "aws_proxy" &&
            can(operation["x-amazon-apigateway-integration"].uri) && ! can(regex("lambda:path", operation["x-amazon-apigateway-integration"].uri))) ?
            ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: aws_proxy integration must target a Lambda function"] : [],
          # AWS service integrations (non-Lambda) should have credentials
          (operation["x-amazon-apigateway-integration"].type == "aws" &&
            can(operation["x-amazon-apigateway-integration"].uri) && ! can(regex("lambda:", operation["x-amazon-apigateway-integration"].uri)) &&
            operation["x-amazon-apigateway-integration"].credentials == null) ?
            ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: AWS service integration missing IAM credentials"] : [],
          # AWS (non-proxy) and HTTP (non-proxy) integrations should define integration response mappings (for transforming backend responses)
          (operation["x-amazon-apigateway-integration"].type == "aws" &&
            (operation["x-amazon-apigateway-integration"].responses == null || length(keys(operation["x-amazon-apigateway-integration"].responses)) == 0)) ?
            ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: AWS integration missing integration response mappings"] : [],
          (operation["x-amazon-apigateway-integration"].type == "http" &&
            (operation["x-amazon-apigateway-integration"].responses == null || length(keys(operation["x-amazon-apigateway-integration"].responses)) == 0)) ?
            ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: HTTP integration missing integration response mappings"] : [],
          # Mock integrations should not specify a URI or httpMethod
          (operation["x-amazon-apigateway-integration"].type == "mock" &&
            (operation["x-amazon-apigateway-integration"].uri != null || operation["x-amazon-apigateway-integration"].httpMethod != null)) ?
            ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: Mock integration should not define a URI or httpMethod"] : [],
          # connectionType should only appear for HTTP/HTTP_PROXY integrations
          (operation["x-amazon-apigateway-integration"].connectionType != null &&
            ! contains(["http","http_proxy"], operation["x-amazon-apigateway-integration"].type)) ?
            ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: connectionType is not applicable for integration type '${operation["x-amazon-apigateway-integration"].type}'"] : [],
          # connectionId without proper connectionType
          (operation["x-amazon-apigateway-integration"].connectionId != null &&
            lower(try(operation["x-amazon-apigateway-integration"].connectionType, "")) != "vpc_link") ?
            ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: connectionId provided without connectionType 'VPC_LINK'"] : []
        ) : [],

        # 3. Check that responses are defined for the operation
        ((operation.responses == null || length(keys(operation.responses)) == 0) ?
          ["Path ${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)}: no responses defined"] :
          [])
      )
    ]
  ])

  # Consolidate all errors from the above checks
  errors = concat(
    local.spec_file_exists ? [] : ["Spec file not found at path '${var.openapi_spec_path}'"],
    local.spec_file_exists ? concat(
      local.version_valid ? [] : ["Unsupported OpenAPI/Swagger version '${local.openapi_version}'. Must be 3.0.x or 2.0."],
      local.info_valid ? [] : ["Missing API info title or version"],
      local.paths_valid ? [] : ["No paths defined in the API spec"],
      local.usage_plan_errors,
      local.operation_errors
    ) : []
  )

  spec_valid = length(local.errors) == 0
}

# Output flag indicating if the spec passed all validations
output "openapi_spec_valid" {
  value       = local.spec_valid
  description = "True if the OpenAPI spec file is structurally compatible with aws_api_gateway_rest_api.body"
  # (Optionally, you could add an output precondition here as well if using Terraform 1.3+)
}

# Output summary of each path and method with its integration backend category
output "api_paths_integration_summary" {
  value = flatten([
    for path, path_item in local.spec_raw.paths : [
      for method, operation in path_item :
      # Only include real operations (skip parameters keys)
      if !(method == "parameters" || (startswith(method, "x-") && method != "x-amazon-apigateway-any-method")) :
        "${path} ${method == "x-amazon-apigateway-any-method" ? "ANY" : upper(method)} -> ${
          can(operation["x-amazon-apigateway-integration"]) ?
            (
              operation["x-amazon-apigateway-integration"].type == "aws_proxy" ?
                (can(regex("lambda:path", operation["x-amazon-apigateway-integration"].uri)) ? "lambda" : "aws_proxy") :
              operation["x-amazon-apigateway-integration"].type == "aws" ?
                (can(regex("lambda:", operation["x-amazon-apigateway-integration"].uri)) ? "lambda" : "aws_service") :
              operation["x-amazon-apigateway-integration"].type == "http_proxy" ?
                (lower(try(operation["x-amazon-apigateway-integration"].connectionType, "")) == "vpc_link" ? "ecs" : "http_proxy") :
              operation["x-amazon-apigateway-integration"].type == "http" ?
                (lower(try(operation["x-amazon-apigateway-integration"].connectionType, "")) == "vpc_link" ? "ecs" : "http") :
              operation["x-amazon-apigateway-integration"].type == "mock" ?
                "mock" :
              "unknown"
            )
          : "NO-INTEGRATION"
        }"
    ]
  ])
  description = "List of path/method -> backend integration type (e.g. lambda, ecs, http_proxy, etc.)"
}

# Use a null_resource with precondition to fail planning if spec is invalid
resource "null_resource" "validate_openapi_spec" {
  # Trigger resource each plan/apply (so preconditions are evaluated every time)
  triggers = { always_run = timestamp() }

  precondition {
    condition     = local.spec_valid
    error_message = "OpenAPI spec validation failed:\n- ${join("\n- ", local.errors)}"
  }
}
```

**Usage:** Include this file in your Terraform configuration. Set `var.openapi_spec_path` to the location of your OpenAPI YAML. Run `terraform plan` – if the spec violates any rule, the plan will abort with a detailed error list. Otherwise, the outputs will confirm the spec is valid and show a summary of each path’s integration type.
