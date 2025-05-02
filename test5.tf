###############################################################################
# semantic_check.tf  –  Terraform 1.7.x
# Validate openapi spec (apikey sample you provided)
###############################################################################

locals {
  ###########################################################################
  # 1.  Load spec
  ###########################################################################
  spec_path = "${path.module}/specs/openapispec_apikey.yaml"
  openapi_spec = yamldecode(file(local.spec_path))

  # convenience shortcut ----------------------------------------------------
  paths            = try(local.openapi_spec.paths, {})
  recognised_keys  = toset([
    "get","post","put","delete","patch","head","options",
    "x-amazon-apigateway-any-method"
  ])
  ext_any          = "x-amazon-apigateway-any-method"

  ###########################################################################
  # 2.  Flatten paths → operations  (path + verb + op-object)
  ###########################################################################
  all_ops = flatten([
    for p, pdef in local.paths : [
      for m, op in pdef : {
        path   = p
        method = m
        op     = op
      } if contains(local.recognised_keys, m)
    ]
  ])

  ###########################################################################
  # 3.  Individual rule checks (r1 … rN)
  ###########################################################################

  # r1 – spec must be OpenAPI 3
  r1_openapi_3 = can(local.openapi_spec.openapi) && startswith(local.openapi_spec.openapi, "3.")

  # r2 – must have at least one path
  r2_has_paths = length(local.paths) > 0

  # r3 – every op has a 2xx or 201 response
  r3_ops_have_2xx = alltrue([
    for o in local.all_ops : length([
      for k, _ in try(o.op.responses, {}) : k if regex("^2\\d\\d", k)
    ]) > 0
  ])

  # r4 – endpoint type must be PRIVATE
  r4_endpoint_private = (
    can(local.openapi_spec["x-amazon-apigateway-endpoint-configuration"].types)
    && contains(
      local.openapi_spec["x-amazon-apigateway-endpoint-configuration"].types,
      "PRIVATE"
    )
  )

  # r5 – stage must be dev
  r5_stage_dev = (
    can(local.openapi_spec["x-amazon-apigateway-stage"])
    && local.openapi_spec["x-amazon-apigateway-stage"] == "dev"
  )

  # r6 – info section complete
  r6_info_complete = (
    can(local.openapi_spec.info.title)   && trimspace(local.openapi_spec.info.title)   != "" &&
    can(local.openapi_spec.info.version) && trimspace(local.openapi_spec.info.version) != ""
  )

  # r7 – only recognised verbs
  r7_allowed_verbs_only = alltrue([
    for o in local.all_ops : contains(local.recognised_keys, o.method)
  ])

  # r8 – every op has a non-blank summary  (allow summary to be absent)
  r8_ops_have_summary = alltrue([
    for o in local.all_ops :
    !(lookup(o.op, "summary", "") == "")   # ok if summary key not present or not blank
  ])

  # r9 – each op documents at least one 4xx & one 5xx
  r9_ops_have_4xx_5xx = alltrue([
    for o in local.all_ops : (
      length([for k,_ in try(o.op.responses, {}) : k if regex("^4\\d\\d", k)]) > 0 &&
      length([for k,_ in try(o.op.responses, {}) : k if regex("^5\\d\\d", k)]) > 0
    )
  ])

  # r10 – each op has an integration block
  r10_all_ops_have_int = alltrue([
    for o in local.all_ops : can(o.op["x-amazon-apigateway-integration"])
  ])

  # r11 – usage-plan limits positive & period in {MONTH,WEEK,DAY}
  valid_quota_periods = ["MONTH","WEEK","DAY"]
  r11_usage_plans_valid = alltrue([
    for o in local.all_ops : alltrue([
      for plan in try(o.op["x-amazon-apigateway-usage-plans"], []) :
        plan.throttle.rateLimit  > 0 &&
        plan.throttle.burstLimit > 0 &&
        plan.quota.limit         > 0 &&
        contains(local.valid_quota_periods, plan.quota.period)
    ])
  ])

  ###########################################################################
  # 4.  Extra diagnostics – missing integrations etc.
  ###########################################################################
  integration_errors = [
    for o in local.all_ops :
    "${upper(o.method)} ${o.path}: no x-amazon-apigateway-integration"
    if !can(o.op["x-amazon-apigateway-integration"])
  ]

  ###########################################################################
  # 5.  Aggregate verdict + list
  ###########################################################################
  spec_errors = concat(
    local.r1_openapi_3           ? [] : ["Spec is not OpenAPI 3"],
    local.r2_has_paths           ? [] : ["Spec has no paths"],
    local.r3_ops_have_2xx        ? [] : ["Some operations lack 2xx/201 response"],
    local.r4_endpoint_private    ? [] : ["Endpoint not PRIVATE"],
    local.r5_stage_dev           ? [] : ["Stage is not dev"],
    local.r6_info_complete       ? [] : ["info.title/version missing"],
    local.r7_allowed_verbs_only  ? [] : ["Unsupported HTTP verbs present"],
    local.r8_ops_have_summary    ? [] : ["Operations missing summary"],
    local.r9_ops_have_4xx_5xx    ? [] : ["Operations must document 4xx & 5xx"],
    local.r10_all_ops_have_int   ? [] : ["Operations missing integration"],
    local.r11_usage_plans_valid  ? [] : ["Usage-plan limits/quotas invalid"],
    local.integration_errors
  )

  spec_valid = length(local.spec_errors) == 0

  ###########################################################################
  # 6.  Optional: quick summary of backend type per op
  ###########################################################################
  api_paths_integration_summary = {
    for o in local.all_ops :
    "${upper(o.method)} ${o.path}" => (
      can(o.op["x-amazon-apigateway-integration"]) ? (
        lower(try(o.op["x-amazon-apigateway-integration"].type, "")) == "aws_proxy" ? "lambda" :
        lower(try(o.op["x-amazon-apigateway-integration"].type, "")) == "aws" ? (
          contains(
            try(o.op["x-amazon-apigateway-integration"].uri, ""),
            ":lambda:"
          ) ? "lambda" : "aws_service"
        ) :
        lower(try(o.op["x-amazon-apigateway-integration"].type, "")) == "http_proxy" ? "http_proxy" :
        lower(try(o.op["x-amazon-apigateway-integration"].type, "")) == "http" ? "http" :
        (try(o.op["x-amazon-apigateway-integration"].connectionType, "") == "VPC_LINK") ? "vpc_link" :
        "other"
      ) : "NO_INTEGRATION"
    )
  }
}

###############################################################################
# 7.  Enforce via pre-condition
###############################################################################
resource "null_resource" "openapi_guard" {
  lifecycle {
    precondition {
      condition     = local.spec_valid
      error_message = "OpenAPI semantic validation failed:\n${join("\n", local.spec_errors)}"
    }
  }
}

###############################################################################
# 8.  Outputs
###############################################################################
output "openapi_semantic_ok" {
  description = "true => spec passed all validation checks"
  value       = local.spec_valid
}

output "openapi_error_list" {
  description = "all problems found (empty list when spec is good)"
  value       = local.spec_errors
}

output "api_paths_integration_summary" {
  value = local.api_paths_integration_summary
}
