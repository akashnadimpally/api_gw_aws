###############################################################################
#  semantic_check.tf  –  OpenAPI semantic validation (Terraform >= 1.7.4)
###############################################################################
terraform {
  required_version = ">= 1.7.4"
}

###############################################################################
# 1.  Load and decode the OpenAPI YAML file
###############################################################################
locals {
  spec_file = "${path.module}/specs/openapispec_apikey.yaml"      # <-- adjust if needed
  spec      = yamldecode(file(local.spec_file))                   # map(object)

  #############################################################################
  # Convenience handles
  #############################################################################
  paths            = try(local.spec.paths, {})                    # map = {} if missing
  path_names       = sort(keys(local.paths))
  allowed_verbs    = ["get","post","put","delete","patch","head","options"]
  ext_any          = "x-amazon-apigateway-any-method"
  recognised_keys  = concat(local.allowed_verbs, [local.ext_any])

  #############################################################################
  # 2.  Spec-level validations
  #############################################################################
  v_openapi3  = can(local.spec.openapi) && startswith(local.spec.openapi, "3.")
  v_has_paths = length(local.path_names) > 0
  v_info      = (
    can(local.spec.info.title)    && trimspace(local.spec.info.title)    != "" &&
    can(local.spec.info.version)  && trimspace(local.spec.info.version)  != ""
  )

  # Stage must be “dev”
  v_stage_dev = (
    #  a/ via x-amazon-apigateway-stage
    ( can(local.spec["x-amazon-apigateway-stage"]) &&
      local.spec["x-amazon-apigateway-stage"] == "dev")
    ||
    #  b/ first server url contains “/dev”
    ( can(local.spec.servers[0].url) &&
      length(regexall("/dev(/|$)", local.spec.servers[0].url)) > 0 )
  )

  # Endpoint type must be PRIVATE
  v_endpoint_private = (
    can(local.spec["x-amazon-apigateway-endpoint-configuration"].types) &&
    contains(local.spec["x-amazon-apigateway-endpoint-configuration"].types, "PRIVATE")
  )

  #############################################################################
  # 3.  Per-operation checks
  #############################################################################
  #
  # Build a flat list of all {path, method, op-object}
  #
  all_ops = flatten([
    for p, pdef in local.paths : [
      for m, op in pdef :
      # keep only real operations (skip “parameters” etc.)
      {
        path   = p
        method = m
        op     = op
      }
      if contains(local.recognised_keys, m)
    ]
  ])

  # Missing summary
  op_no_summary = [
    for o in local.all_ops : "${o.method} ${o.path}"
    if can(o.op.summary) == false || trimspace(o.op.summary) == ""
  ]

  # HTTP verb must be recognised
  op_bad_verb = [
    for p, pdef in local.paths : [
      for m, _ in pdef : "${m} ${p}"
      if !(contains(local.recognised_keys, m) || m == "parameters")
    ]
  ] |> flatten()

  # 2xx / 4xx / 5xx response presence
  op_no_2xx = [
    for o in local.all_ops : "${o.method} ${o.path}"
    if length([for c in keys(try(o.op.responses, {})) :
               c if can(tonumber(c)) && tonumber(c) >=200 && tonumber(c) <300]) == 0
  ]
  op_no_4xx = [
    for o in local.all_ops : "${o.method} ${o.path}"
    if length([for c in keys(try(o.op.responses, {})) :
               c if can(tonumber(c)) && tonumber(c) >=400 && tonumber(c) <500]) == 0
  ]
  op_no_5xx = [
    for o in local.all_ops : "${o.method} ${o.path}"
    if length([for c in keys(try(o.op.responses, {})) :
               c if can(tonumber(c)) && tonumber(c) >=500 && tonumber(c) <600]) == 0
  ]

  # Integration present + type valid
  allowed_int_types = ["AWS","AWS_PROXY","HTTP","HTTP_PROXY","MOCK"]
  op_missing_integration = [
    for o in local.all_ops : "${o.method} ${o.path}"
    if can(o.op["x-amazon-apigateway-integration"]) == false
  ]
  op_bad_int_type = [
    for o in local.all_ops : "${o.method} ${o.path}"
    if can(o.op["x-amazon-apigateway-integration"]) &&
       !contains(local.allowed_int_types, upper(o.op["x-amazon-apigateway-integration"].type))
  ]

  #############################################################################
  # 4.  Usage-plan validations (top-level extension)
  #############################################################################
  raw_plans = try(local.spec["x-amazon-apigateway-usage-plans"], [])
  usage_plans = (
    raw_plans == null ? [] :
    # if a single map, wrap into list
    (can(keys(raw_plans)) && type(raw_plans) == "map") ? [raw_plans] : raw_plans
  )

  plan_errors = flatten([
    for idx, up in local.usage_plans : concat(
      can(up.name) ? [] : ["Usage plan #${idx} missing .name"],
      !(can(up.throttle.rateLimit))  ? ["Usage plan '${try(up.name,"#"+idx)}' missing throttle.rateLimit"] : [],
      !(can(up.throttle.burstLimit)) ? ["Usage plan '${try(up.name,"#"+idx)}' missing throttle.burstLimit"] : [],
      !(can(up.quota.limit))         ? ["Usage plan '${try(up.name,"#"+idx)}' missing quota.limit"]        : [],
      !(can(up.quota.period) && contains(["MONTH","WEEK","DAY"], up.quota.period)) ?
        ["Usage plan '${try(up.name,"#"+idx)}' quota.period invalid (use MONTH|WEEK|DAY)"] : []
    )
  ])

  #############################################################################
  # 5.  Aggregate **all** errors
  #############################################################################
  spec_errors = concat(
    local.v_openapi3  ? [] : ["Spec is not OpenAPI 3.x"],
    local.v_has_paths ? [] : ["Spec has no paths"],
    local.v_info      ? [] : ["Info.title or Info.version missing"],
    local.v_stage_dev ? [] : ["Stage must be 'dev'"],
    local.v_endpoint_private ? [] : ["Endpoint type must be PRIVATE"],
    [for s in local.op_bad_verb             : "Unrecognised HTTP verb: ${s}"],
    [for s in local.op_no_summary           : "Missing summary: ${s}"],
    [for s in local.op_no_2xx               : "No 2xx response: ${s}"],
    [for s in local.op_no_4xx               : "No 4xx response: ${s}"],
    [for s in local.op_no_5xx               : "No 5xx response: ${s}"],
    [for s in local.op_missing_integration  : "No integration defined: ${s}"],
    [for s in local.op_bad_int_type         : "Bad integration type: ${s}"],
    local.plan_errors
  )

  spec_valid = length(local.spec_errors) == 0

  #############################################################################
  # 6.  Integration-backend summary (optional)
  #############################################################################
  api_paths_integration_summary = {
    for o in local.all_ops :
    "${o.path} ${o.method}" =>
      can(o.op["x-amazon-apigateway-integration"]) ?
      upper(o.op["x-amazon-apigateway-integration"].type) : "NONE"
  }
}

###############################################################################
# 7.  Guard resource – fail plan if spec invalid
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
  value = local.spec_valid
}

output "openapi_error_list" {
  value = local.spec_errors
}

output "api_paths_integration_summary" {
  value = local.api_paths_integration_summary
}
