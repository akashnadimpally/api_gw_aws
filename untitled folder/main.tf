resource "aws_api_gateway_rest_api" "api" {
  name                         = local.api_name
  body                         = jsonencode(local.final_spec)
  disable_execute_api_endpoint = true
  endpoint_configuration {
    types = ["PRIVATE"]
  }
}

resource "aws_api_gateway_rest_api_policy" "api_policy" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  policy = data.aws_iam_policy_document.api_gateway.json
  # lifecycle {
  #   precondition {
  #     condition = !local.use_iam_auth || (local.use_iam_auth && length(local.all_roles) > 0)
  #     error_message = "You must provide base roles"
  #   }
  # }
}

resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  triggers = {
    redeployment = sha1(jsonencode(aws_api_gateway_rest_api.api.body))
  }

  lifecycle {
    create_before_destroy = true
  }
  
}

resource "aws_api_gateway_stage" "release_stage" {
  deployment_id = aws_api_gateway_deployment.deployment.id
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name = local.stage_name
  xray_tracing_enabled = true
}

resource "aws_api_gateway_usage_plan" "api_usage_plan" {
  for_each = local.usage_plans
  name = each.key

  throttle_settings {
    burst_limit = max([for t in each.value.throttles : t.burst_limit]...)
    rate_limit = max([for t in each.value.throttles : t.rate_limit]...)
  }

  dynamic "quota_settings" {
    for_each = each.value.quota_limit != null ? [each.value] : []
    content {
      limit = quota_settings.value.quota_limit
      offset = try(quota_settings.value.quota_offset, 0)
      period = quota_settings.value.quota_period
    }
  }

  api_stages {
    api_id = aws_api_gateway_rest_api.api.id
    stage = aws_api_gateway_stage.release_stage.stage_name
    dynamic "throttle" {
      for_each = each.value.throttles
      content {
        path = "${throttle.value.path}/${upper(throttle.value.method)}"
        burst_limit = throttle.value.burst_limit
        rate_limit = throttle.value.rate_limit
      }
    }
  }
}

resource "aws_api_gateway_api_key" "mrap_api_key" {
  for_each = local.usage_plans
  name = "${each.key}-${var.app_name}-${var.environment}-${var.region}-apikey"
  enabled = true
  lifecycle {
    ignore_changes = [ value ]
    prevent_destroy = true
  }
}

resource "aws_api_gateway_usage_plan_key" "mrap_api_key_usage_plan" {
  for_each = local.usage_plans
  key_id = aws_api_gateway_api_key.mrap_api_key[each.key].id
  key_type = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.api_usage_plan[each.key].id
}