###############################################################################
#  semantic_check.tf – now with extra OpenAPI validations (R6-R11)
###############################################################################

locals {
  # path to the spec file you showed
  spec_path = "${path.module}/specs/apikey.yaml"
  spec      = yamldecode(file(local.spec_path))

  ############  ORIGINAL RULES (R1-R5)  #######################################
  oas_is_openapi3     = local.spec.openapi != null && startswith(local.spec.openapi, "3.")
  oas_has_paths       = can(length(local.spec.paths)) && length(local.spec.paths) > 0
  oas_all_ops_success = alltrue([
    for _, ops in local.spec.paths : alltrue([
      for _, op in ops : can(op.responses["200"]) || can(op.responses["201"])
    ])
  ])
  oas_endpoint_private = (
    can(local.spec["x-amazon-apigateway-endpoint-configuration"].types)
    && contains(local.spec["x-amazon-apigateway-endpoint-configuration"].types, "PRIVATE")
  )
  oas_stage_dev = (
    can(local.spec["x-amazon-apigateway-stage"])
    && local.spec["x-amazon-apigateway-stage"] == "dev"
  )
  oas_apikey_security = (
    can(local.spec.components.securitySchemes.ApiKeyAuth)
    && local.spec.components.securitySchemes.ApiKeyAuth.type == "apiKey"
    && local.spec.components.securitySchemes.ApiKeyAuth.in   == "header"
    && local.spec.components.securitySchemes.ApiKeyAuth.name == "x-api-key"
  )
  oas_all_ops_have_integration = alltrue([
    for _, ops in local.spec.paths : alltrue([
      for _, op in ops :
        can(op["x-amazon-apigateway-integration"])
        && contains(["aws_proxy", "aws"], op["x-amazon-apigateway-integration"].type)
    ])
  ])
  oas_all_ops_usage_plans_positive = alltrue([
    for _, ops in local.spec.paths : alltrue([
      for _, op in ops :
        can(op["x-amazon-apigateway-usage-plans"]) && length([
          for plan in op["x-amazon-apigateway-usage-plans"] :
            plan.throttle.rateLimit  > 0 &&
            plan.throttle.burstLimit > 0 &&
            plan.quota.limit         > 0
        ]) == length(op["x-amazon-apigateway-usage-plans"])
    ])
  ])

  ############  NEW RULES (R6-R11)  ###########################################

  # R6 – info section completeness
  oas_info_valid = (
    can(local.spec.info.title)    && trim(local.spec.info.title)    != ""
    && can(local.spec.info.version) && trim(local.spec.info.version) != ""
  )

  # R7 – allowed HTTP verbs only
  allowed_verbs                = ["get","post","put","delete","patch","head","options"]
  oas_all_ops_allowed_verbs = alltrue([
    for _, ops in local.spec.paths : alltrue([
      for verb, _ in ops : contains(local.allowed_verbs, verb)
    ])
  ])

  # R8 – every operation has summary
  oas_all_ops_have_summary = alltrue([
    for _, ops in local.spec.paths : alltrue([
      for _, op in ops : can(op.summary) && trim(op.summary) != ""
    ])
  ])

  # R9 – every operation documents at least one 4xx and one 5xx
  oas_all_ops_error_responses = alltrue([
    for _, ops in local.spec.paths : alltrue([
      for _, op in ops : (
        length([for k,_ in op.responses : startswith(k,"4")]) > 0 &&
        length([for k,_ in op.responses : startswith(k,"5")]) > 0
      )
    ])
  ])

  # R10 – integration URI present and non-empty
  oas_all_ops_have_uri = alltrue([
    for _, ops in local.spec.paths : alltrue([
      for _, op in ops : can(op["x-amazon-apigateway-integration"].uri) &&
                         op["x-amazon-apigateway-integration"].uri != ""
    ])
  ])

  # R11 – usage-plan throttle / quota valid & period allowed
  valid_quota_periods = ["MONTH","WEEK","DAY"]
  oas_all_ops_usage_plans_valid = alltrue([
    for _, ops in local.spec.paths : alltrue([
      for _, op in ops : alltrue([
        for plan in op["x-amazon-apigateway-usage-plans"] :
          plan.throttle.rateLimit  > 0 &&
          plan.throttle.burstLimit > 0 &&
          plan.quota.limit         > 0 &&
          contains(local.valid_quota_periods, plan.quota.period)
      ])
    ])
  ])

  ############  MASTER SWITCH  ################################################
  oas_semantic_ok = (
    local.oas_is_openapi3
    && local.oas_has_paths
    && local.oas_all_ops_success
    && local.oas_endpoint_private
    && local.oas_stage_dev
    && local.oas_apikey_security
    && local.oas_all_ops_have_integration
    && local.oas_all_ops_usage_plans_positive
    && local.oas_info_valid                     # R6
    && local.oas_all_ops_allowed_verbs          # R7
    && local.oas_all_ops_have_summary           # R8
    && local.oas_all_ops_error_responses        # R9
    && local.oas_all_ops_have_uri               # R10
    && local.oas_all_ops_usage_plans_valid      # R11
  )
}

resource "null_resource" "oas_guard" {
  lifecycle {
    precondition {
      condition     = local.oas_semantic_ok
      error_message = "openapi.yaml failed one or more semantic validations (see semantic_check.tf for full list)."
    }
  }
}

output "openapi_semantic_ok" {
  value = local.oas_semantic_ok
}
