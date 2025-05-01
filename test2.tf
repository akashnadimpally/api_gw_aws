###############################################################################
# semantic_check.tf – OpenAPI 3.0 semantic verification for API Gateway
# (Terraform ≥1.3)
###############################################################################

########################
# 1. Load the spec file
########################
locals {
  # ► modify this if your yaml lives in another folder / name
  spec_path = "${path.module}/specs/apikey.yaml"

  # decoded openapi document (map(object))
  spec      = yamldecode(file(local.spec_path))

  # convenience
  paths     = try(local.spec.paths, {})
}

########################
# 2. Generic helpers
########################
locals {
  recognized_verbs = [
    "get","post","put","delete","patch","head","options",
    # API-Gateway extension
    "x-amazon-apigateway-any-method",
  ]

  # path list
  path_names = sort(keys(local.paths))

  # verb list per path
  path_verbs = {
    for p, def in local.paths :
    p => [for k in keys(def) : k if k in local.recognized_verbs]
  }
}

########################
# 3.  R1-R11  baseline rules
########################
locals {
  r1_openapi_3   = can(local.spec.openapi) && startswith(local.spec.openapi, "3.")
  r2_has_paths   = length(local.paths) > 0

  r3_all_ops_have_2xx = alltrue([
    for _, ops in local.paths : alltrue([
      for _, op in ops :
        length([for k, _ in try(op.responses, {}) : k if startswith(k,"2")]) > 0
    ])
  ])

  r4_endpoint_private = (
    can(local.spec["x-amazon-apigateway-endpoint-configuration"].types) &&
    contains(
      local.spec["x-amazon-apigateway-endpoint-configuration"].types,
      "PRIVATE"
    )
  )

  r5_stage_dev = (
    can(local.spec["x-amazon-apigateway-stage"]) &&
    local.spec["x-amazon-apigateway-stage"] == "dev"
  )

  r6_info_complete = (
    can(local.spec.info.title)   && trim(local.spec.info.title)   != "" &&
    can(local.spec.info.version) && trim(local.spec.info.version) != ""
  )

  r7_allowed_verbs_only = alltrue([
    for _, ops in local.paths : alltrue([
      for v, _ in ops : contains(local.recognized_verbs, v)
    ])
  ])

  r8_ops_have_summary = alltrue([
    for _, ops in local.paths : alltrue([
      for _, op in ops : can(op.summary) && trim(op.summary) != ""
    ])
  ])

  r9_ops_have_4xx_5xx = alltrue([
    for _, ops in local.paths : alltrue([
      for _, op in ops :
        length([for k,_ in try(op.responses, {}) : k if startswith(k,"4")]) > 0 &&
        length([for k,_ in try(op.responses, {}) : k if startswith(k,"5")]) > 0
    ])
  ])

  r10_all_ops_have_int = alltrue([
    for _, ops in local.paths : alltrue([
      for _, op in ops : can(op["x-amazon-apigateway-integration"])
    ])
  ])

  # quota period must be one of …
  valid_quota_periods = ["MONTH","WEEK","DAY"]

  r11_usage_plans_valid = alltrue([
    for _, ops in local.paths : alltrue([
      for _, op in ops :
        alltrue([
          for plan in try(op["x-amazon-apigateway-usage-plans"], []) :
            plan.throttle.rateLimit  > 0 &&
            plan.throttle.burstLimit > 0 &&
            plan.quota.limit         > 0 &&
            contains(local.valid_quota_periods, plan.quota.period)
        ])
    ])
  ])
}

########################
# 4. Integration-level sanity
########################
locals {
  integration_errors = flatten([
    for path, ops in local.paths : [
      for verb, op in ops : (
        can(op["x-amazon-apigateway-integration"])
        ? (
            # shortcut
            {
              int = op["x-amazon-apigateway-integration"]
            }
          ) : {
              # missing integration altogether
              error = "${path} ${verb}: ❌ no x-amazon-apigateway-integration"
            }
      )
      # turn the small objects above into free-form error strings
      => (
        (!can(op["x-amazon-apigateway-integration"]))
        ? [_.error]

        # if integration exists, run deeper checks
        : [
            # connectionId / connectionType pair consistency
            (
              (try(_.int.connectionType, null) != null) !=
              (try(_.int.connectionId,  null) != null)
            )
              ? "${path} ${verb}: connectionType & connectionId must appear together"
              : null,

            # credentials needed for Lambda when type is aws/aws_proxy
            (
              contains(["aws","aws_proxy"], lower(try(_.int.type,""))) &&
              contains(try(_.int.uri,""),":lambda:") &&
              try(_.int.credentials,null) == null
            )
              ? "${path} ${verb}: missing credentials for Lambda integration"
              : null,

            # empty 'responses' only allowed for *_proxy types
            (
              length(keys(try(_.int.responses, {}))) == 0 &&
              !contains(["http_proxy","aws_proxy"], lower(try(_.int.type,"")))
            )
              ? "${path} ${verb}: responses{} empty for non-proxy integration"
              : null
          ]
      )
    ]
  ])

  # strip nulls
  integration_errors_clean = [for e in local.integration_errors : e if e != null]

  integrations_ok = length(local.integration_errors_clean) == 0
}

########################
# 5. Overall pass/fail
########################
locals {
  spec_errors = concat(
    local.r1_openapi_3           ? [] : ["Spec is not OpenAPI 3"],
    local.r2_has_paths           ? [] : ["Spec has no paths"],
    local.r3_all_ops_have_2xx    ? [] : ["Some operations lack 2xx response"],
    local.r4_endpoint_private    ? [] : ["Endpoint configuration not PRIVATE"],
    local.r5_stage_dev           ? [] : ["Stage is not 'dev'"],
    local.r6_info_complete       ? [] : ["info.title/version missing"],
    local.r7_allowed_verbs_only  ? [] : ["Unsupported HTTP verb present"],
    local.r8_ops_have_summary    ? [] : ["Some operations missing summary"],
    local.r9_ops_have_4xx_5xx    ? [] : ["Operations must document 4xx & 5xx"],
    local.r10_all_ops_have_int   ? [] : ["Operation(s) missing integration"],
    local.r11_usage_plans_valid  ? [] : ["Usage-plan limits/quota invalid"],
    local.integration_errors_clean
  )

  spec_valid = length(local.spec_errors) == 0
}

#####################################
# 6. Fail the plan when invalid spec
#####################################
resource "null_resource" "openapi_guard" {
  lifecycle {
    precondition {
      condition     = local.spec_valid
      error_message = "OpenAPI semantic validation failed:\n${join("\n", local.spec_errors)}"
    }
  }
}

########################
# 7. Friendly outputs
########################
output "openapi_semantic_ok" {
  description = "true ⇢ spec passed all validation checks"
  value       = local.spec_valid
}

output "openapi_error_list" {
  description = "All problems found (empty list when spec is good)"
  value       = local.spec_errors
}

# Simple summary of backend category (lambda / http_proxy / vpc_link / etc.)
output "api_paths_integration_summary" {
  value = {
    for p, ops in local.paths :
    p => {
      for v, op in ops :
      v => (
        can(op["x-amazon-apigateway-integration"]) ? (
          # classify safely
          (
            lower(try(op["x-amazon-apigateway-integration"].type,"")) == "aws_proxy"
          )
            ? "lambda"
          : lower(try(op["x-amazon-apigateway-integration"].type,"")) == "http_proxy"
            ? "http_proxy"
          : try(op["x-amazon-apigateway-integration"].connectionType,"") == "VPC_LINK"
            ? "vpc_link"
          : lower(try(op["x-amazon-apigateway-integration"].type,""))
        )
        : "NONE"
      )
    }
  }
}
