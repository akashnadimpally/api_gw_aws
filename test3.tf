###############################################################################
# semantic_check.tf – single-file implementation
###############################################################################

locals {
  # ── 1.  Load spec ────────────────────────────────────────────────────────────
  spec_path = "${path.module}/specs/openapispec_apikey.yaml"   # <-- change if needed
  spec      = yamldecode(file(local.spec_path))

  # handy shortcuts
  paths            = try(local.spec.paths, {})
  recognized_verbs = [
    "get","post","put","delete","patch","head","options",
    "x-amazon-apigateway-any-method",
  ]

  # ── 2.  Path & verb inventory ───────────────────────────────────────────────
  path_names = sort(keys(local.paths))

  path_verbs = {
    for p, def in local.paths :
    p => [for k in keys(def) : k if contains(local.recognized_verbs, k)]
  }

  # ── 3.  Convenience helpers --------------------------------------------------
  trim_nonempty = function(str) => length(trimspace(str)) > 0

  has_2xx = function(op) => length([
    for k, _ in try(op.responses, {}) : k
    if startswith(k, "2")
  ]) > 0

  has_4xx_5xx = function(op) =>
    length([for k, _ in try(op.responses, {}) : k if startswith(k,"4")]) > 0 &&
    length([for k, _ in try(op.responses, {}) : k if startswith(k,"5")]) > 0

  integration_obj = function(op) =>
    try(op["x-amazon-apigateway-integration"], null)

  integ_type   = function(op) => lower(try(local.integration_obj(op).type, ""))
  connection_t = function(op) => upper(try(local.integration_obj(op).connectionType, ""))
  has_integr   = function(op) => local.integration_obj(op) != null

  classify_backend = function(op) => (
      local.integ_type(op) == "aws_proxy" ? "lambda" :
      local.integ_type(op) == "aws" && contains(try(local.integration_obj(op).uri,""), ":lambda:")
        ? "lambda" :
      local.integ_type(op) == "http_proxy" ? "http_proxy" :
      local.integ_type(op) == "http"       ? "http"       :
      local.connection_t(op) == "VPC_LINK" ? "vpc_link"   :
      local.integ_type(op) == "mock"       ? "mock"       :
      "unknown"
  )

  # ── 4.  Validation rules (R-series) ─────────────────────────────────────────
  r1_openapi3   = can(local.spec.openapi) && startswith(local.spec.openapi,"3.")
  r2_has_paths  = length(local.paths) > 0

  r3_all_ops_2xx = alltrue([
    for _, ops in local.paths : alltrue([ for _, op in ops : local.has_2xx(op) ])
  ])

  r4_endpoint_private = (
    can(local.spec["x-amazon-apigateway-endpoint-configuration"].types) &&
    contains(local.spec["x-amazon-apigateway-endpoint-configuration"].types,"PRIVATE")
  )

  r5_stage_dev = (
    can(local.spec["x-amazon-apigateway-stage"]) &&
    local.spec["x-amazon-apigateway-stage"] == "dev"
  )

  r6_info_complete = (
    can(local.spec.info.title)   && local.trim_nonempty(local.spec.info.title) &&
    can(local.spec.info.version) && local.trim_nonempty(local.spec.info.version)
  )

  r7_allowed_verbs_only = alltrue([
    for _, ops in local.paths : alltrue([
      for v, _ in ops : contains(local.recognized_verbs, v)
    ])
  ])

  r8_ops_have_summary = alltrue([
    for _, ops in local.paths : alltrue([
      for _, op in ops : can(op.summary) && local.trim_nonempty(op.summary)
    ])
  ])

  r9_ops_have_4xx_5xx = alltrue([
    for _, ops in local.paths : alltrue([
      for _, op in ops : local.has_4xx_5xx(op)
    ])
  ])

  r10_all_ops_have_int = alltrue([
    for _, ops in local.paths : alltrue([
      for _, op in ops : local.has_integr(op)
    ])
  ])

  valid_quota_periods = ["MONTH","WEEK","DAY"]

  r11_usage_plans_valid = alltrue([
    for _, ops in local.paths : alltrue([
      for _, op in ops : alltrue([
        for plan in try(op["x-amazon-apigateway-usage-plans"], []) :
          plan.throttle.rateLimit  > 0 &&
          plan.throttle.burstLimit > 0 &&
          plan.quota.limit         > 0 &&
          contains(local.valid_quota_periods, plan.quota.period)
      ])
    ])
  ])

  # ── 5.  Detailed per-operation integration check (nice error list) ─────────
  integration_errors = flatten([
    for path, ops in local.paths : [
      for verb, op in ops :
        local.has_integr(op) ? (
          []                                                       # OK
        ) : [
          "${path}  ${upper(verb)} : no x-amazon-apigateway-integration"
        ]
    ]
  ])

  # strip nulls / flatten
  integration_errors_clean = [for e in local.integration_errors : e if e != ""]

  # ── 6.  Aggregate verdict & error list ─────────────────────────────────────
  spec_errors = concat(
    local.r1_openapi3            ? [] : ["Spec is not OpenAPI 3"],
    local.r2_has_paths           ? [] : ["Spec has no paths"],
    local.r3_all_ops_2xx         ? [] : ["Some operations lack any 2xx response"],
    local.r4_endpoint_private    ? [] : ["Endpoint configuration is not PRIVATE"],
    local.r5_stage_dev           ? [] : ["Stage is not 'dev'"],
    local.r6_info_complete       ? [] : ["info.title/version missing"],
    local.r7_allowed_verbs_only  ? [] : ["Unsupported HTTP verb present"],
    local.r8_ops_have_summary    ? [] : ["Operations without summary"],
    local.r9_ops_have_4xx_5xx    ? [] : ["Operations missing 4xx & 5xx responses"],
    local.r10_all_ops_have_int   ? [] : ["Some operations lack integration"],
    local.r11_usage_plans_valid  ? [] : ["Usage-plan limits/quotas invalid"],
    local.integration_errors_clean
  )

  spec_valid = length(local.spec_errors) == 0
}

###############################################################################
# Guard resource – stops plan if spec fails
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
# Helpful outputs
###############################################################################
output "openapi_semantic_ok" {
  description = "true ⇢ spec passed all validation checks"
  value       = local.spec_valid
}

output "openapi_error_list" {
  description = "All problems found (empty list when spec is good)"
  value       = local.spec_errors
}

output "api_paths_integration_summary" {
  description = "Quick view of each <path>.<verb> → backend category"
  value = {
    for p, ops in local.paths :
    p => {
      for v, op in ops :
      v => local.classify_backend(op)
    }
  }
}
