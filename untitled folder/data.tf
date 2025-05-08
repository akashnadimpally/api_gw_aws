data "aws_caller_identity" "current" {}

data "aws_region" "region" {

}

data "aws_vpc_endpoint" "lab_execute_api" {
  service_name = "com.amazonaws.us-east-1.execute-api"
}

data "aws_iam_policy" "lambda_basic_exec" {
  name = "AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_policy_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = [
        "lambda.amazonaws.com"
      ]
    }
  }
}

###############################################################################
# data.tf — API Gateway IAM policy (exactly as shown in your screenshots)
###############################################################################

data "aws_iam_policy_document" "api_gateway" {

  # --------------------------------------------------------------------------
  # 1) 100 % open in DEV – let people test freely
  # --------------------------------------------------------------------------
  statement {
    actions = ["execute-api:Invoke"]
    effect  = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      "${aws_api_gateway_rest_api.api.execution_arn}/${local.stage_name}/*"
    ]
  }

  # --------------------------------------------------------------------------
  # 2) Path‑specific *deny* blocks generated from local.verb_policies
  #    (this keeps the console “TEST” button usable in dev)
  # --------------------------------------------------------------------------
  dynamic "statement" {
    for_each = local.verb_policies # map(string=>list(string))

    content {
      actions = ["execute-api:Invoke"]
      effect  = "Deny"

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "StringNotLike"
        values   = compact(coalesce(statement.value, [])) # list of ARNs allowed
        variable = "aws:PrincipalArn"
      }

      resources = [
        "${aws_api_gateway_rest_api.api.execution_arn}/${local.stage_name}/${statement.key}"
      ]
    }
  }

  # --------------------------------------------------------------------------
  # 3) If IAM auth is ON: deny callers whose role ARN is *not* in
  #    local.all_roles (trusted list)
  # --------------------------------------------------------------------------
  dynamic "statement" {
    for_each = local.use_iam_auth ? [local.all_roles] : []

    content {
      actions = ["execute-api:Invoke"]
      effect  = "Deny"

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "StringNotLike"
        values   = compact(coalesce(statement.value, [])) # list of trusted role ARNs
        variable = "aws:PrincipalArn"
      }

      resources = [
        "${aws_api_gateway_rest_api.api.execution_arn}/*"
      ]
    }
  }

  # --------------------------------------------------------------------------
  # 4) Block requests that do **not** come through the approved VPC endpoint
  # --------------------------------------------------------------------------
  statement {
    actions = ["execute-api:*"]
    effect  = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      "${aws_api_gateway_rest_api.api.execution_arn}/*"
    ]

    condition {
      test     = "StringNotEquals"
      values   = [data.aws_vpc_endpoint.lab_execute_api.id]
      variable = "aws:SourceVpc"
    }
  }

  # --------------------------------------------------------------------------
  # 5) If IAM auth is ON: block callers *outside* the organisation
  # --------------------------------------------------------------------------
  dynamic "statement" {
    for_each = local.use_iam_auth ? ["org_block"] : []

    content {
      actions = ["execute-api:*"]
      effect  = "Deny"

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      resources = [
        "${aws_api_gateway_rest_api.api.execution_arn}/*"
      ]

      condition {
        test     = "StringNotEquals"
        values   = ["$${aws:ResourceOrgID}"]
        variable = "aws:PrincipalOrgID"
      }
    }
  }

  # --------------------------------------------------------------------------
  # 6) Optional OU‑protection – only if var.protect_ou_env is true
  # --------------------------------------------------------------------------
  dynamic "statement" {
    for_each = toset(var.protect_ou_env && local.use_iam_auth ? [local.ou_environment] : [])

    content {
      actions = ["execute-api:*"]
      effect  = "Deny"

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      resources = [
        "${aws_api_gateway_rest_api.api.execution_arn}/*"
      ]

      condition {
        test     = "StringNotLike"
        values   = ["*._OU-${statement.key}_*"]
        variable = "aws:PrincipalOrgPaths"
      }
    }
  }
}
