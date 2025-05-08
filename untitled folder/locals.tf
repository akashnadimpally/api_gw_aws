###############################################################################
# locals.tf – straight copy from screenshots
###############################################################################

locals {
  # ---------------------------------------------------------------------------
  #  Generic environment / role helpers
  # ---------------------------------------------------------------------------

  t_env = lower(var.environment)

  ou_environment = local.t_env == "dev" ? "dev" : local.t_env == "lab" || local.t_env == "sandbox" ? "Lab" : local.t_env == "lockout" ? "Lockout" : local.t_env == "pci_prod" ? "PCI_Prod" : local.t_env == "prod" ? "Prod" : "unknown" # fallback

  all_roles = toset(concat(
    var.trusted_roles,
    flatten([
      for i, roles in local.verb_policies : roles
    ])
  ))

  # ---------------------------------------------------------------------------
  #  Normalise verb‑based role map coming from the spec
  # ---------------------------------------------------------------------------

  verb_policies = {
    for i, data in local.verb_policies_almost :
    "${data.verb}${data.path}" => data.roles...
  }

  verb_policies_almost = merge(flatten([
    for path, config in local.temp_verb_policies : [
      {
        for verb, roles in config :
        "${verb}${path}" => {
          roles = roles
          verb  = upper(verb)
          path = join("/", [
            for portion in split("/", path) :
            length(regexall("^[A-Za-z0-9]+$", portion)) == 0 ? portion : "*"
          ])
        }
      }
    ]
  ])...)

  # ---------------------------------------------------------------------------
  #  Bring the OpenAPI document into Terraform
  # ---------------------------------------------------------------------------

  temp_spec = yamldecode(
    file("${path.module}/${var.openapi_spec}")
  )

  # Pull `x‑bank-authorization` values (per method)
  temp_verb_policies = {
    for path, structure in local.temp_spec["paths"] : path => {
      for verb, config in try(structure, {}) :
      (
        lower(verb) == "x-amazon-apigateway-any-method" ? "*" : lower(verb)
        ) => (
        contains(
          try(keys(try(config, {})), []), local.bank_x_key
        )
        ? lookup(config, local.bank_x_key, null)
        : null
      ) if contains(local.recognised_keys, lower(verb))
    }
  }

  bank_x_key = "x-bank-authorization"

  recognised_keys = toset(["get", "post", "put", "delete", "patch", "head", "options", "x-amazon-apigateway-any-method"])

  # Strip the x‑bank-authorization blocks out of the spec
  new_paths = {
    for path, structure in local.temp_spec.paths :
    path => {
      for verb, config in structure :
      verb => {
        for item, cfg in config :
        item => cfg if item != local.bank_x_key
      }
    }
  }

  use_iam_auth = try(contains(keys(local.temp_spec.components.securitySchemes), "sigv4"), false)

  # ---------------------------------------------------------------------------
  #  Final, cleaned spec (without the internal auth blocks)
  # ---------------------------------------------------------------------------

  final_spec = merge(
    local.temp_spec,
    { paths = local.new_paths }
  )

  stage_name = lookup(
    local.temp_spec,
    "x-amazon-apigateway-stage",
    lookup(local.temp_spec, "x-stageName", local.t_env)
  )

  # ---------------------------------------------------------------------------
  #  Usage‑plan harvesting
  # ---------------------------------------------------------------------------

  usage_plan_entries = flatten([
    for path, pathtem in try(local.temp_spec.paths, {}) : [
      for method, operation in try(pathtem, {}) :
      (
        contains(
          try(keys(try(operation, {})), []),
          "x-amazon-apigateway-usage-plans"
        )
        ? [
          for plan in operation["x-amazon-apigateway-usage-plans"] : {
            plan         = plan.name
            path         = path
            method       = upper(method)
            rate_limit   = try(plan.throttle.rateLimit, 0)
            burst_limit  = try(plan.throttle.burstLimit, 0)
            quota_limit  = try(plan.quota.limit, 0)
            quota_period = try(plan.quota.period, "")
          }
        ]
        : []
      )
    ]
  ])

  usage_plans = {
    for plan_name in distinct([for e in local.usage_plan_entries : e.plan]) :
    plan_name => {
      throttles = [
        for e in local.usage_plan_entries : {
          path        = e.path
          method      = e.method
          rate_limit  = e.rate_limit
          burst_limit = e.burst_limit
        } if e.plan == plan_name
      ]

      quota_limit = length(
        [for e in local.usage_plan_entries : e.quota_limit if e.plan == plan_name]
      ) > 0 ? [for e in local.usage_plan_entries : e.quota_limit if e.plan == plan_name][0] : 0

      quota_period = length(
        [for e in local.usage_plan_entries : e.quota_period if e.plan == plan_name]
      ) > 0 ? [for e in local.usage_plan_entries : e.quota_period if e.plan == plan_name][0] : "MONTH"

      quota_offset = var.quota_offset
    }
  }

  # ---------------------------------------------------------------------------
  #  Handy Lambda‑related locals
  # ---------------------------------------------------------------------------

  #   integration_lambda_variables = {
  #     lambda_function_arn = aws_lambda_function.lambda.arn
  #     s3_bucket_name       = var.lambda_s3_bucket
  #     s3_role_arn          = var.lambda_s3_role_arn
  #   }

  lambda_function_name      = "${var.app_name}-${var.environment}-${var.region}-lambda"
  lambda_api_gw_policy_name = "${var.app_name}-${var.environment}-${var.region}-lambda-apigw-logging-iam-policy"
  api_name                  = "${var.app_name}-${var.environment}-${var.region}-restapi"

  # ---------------------------------------------------------------------------
  #  (place‑holder toggles – uncomment if you need them later)
  # ---------------------------------------------------------------------------
  # using_filename      = var.lambda_filename != null && var.lambda_filename != ""
  # using_s3            = var.lambda_s3_bucket != null && var.lambda_s3_bucket_key != null
  # using_image         = var.lambda_image_uri != null && var.lambda_image_uri != ""
  # method_counts       = (local.using_filename ? 1 : 0) + (local.using_s3 ? 1 : 0) + (local.using_image ? 1 : 0)
  # validation_passes   = local.method_counts == 1 && ((var.lambda_s3_bucket == null) && (var.lambda_s3_bucket_key == null))

  # ---------------------------------------------------------------------------
  #  openapi‑semantic‑check scaffolding comes after this
  # ---------------------------------------------------------------------------
}
