resource "aws_iam_role" "lambda_exec" {
   name = "${var.api_config.name}-lambda-exec-role-${replace(var.aws_region, "-", "")}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}


resource "aws_iam_policy" "lambda_ec2_access" {
  name        = "lambda-ec2-access-${var.aws_region}"
  description = "Allows Lambda to manage EC2 network interfaces"
  policy      = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DeleteNetworkInterface"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}



resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_ec2" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_ec2_access.arn
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}




resource "aws_lambda_function" "data_processor" {
  function_name = "data-processor"
  runtime       = "python3.9"
  handler       = "index.lambda_handler"
  role          = aws_iam_role.lambda_exec.arn

  filename         = "${path.module}/lambda/data-processor.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda/data-processor.zip")

  vpc_config {
    subnet_ids         = aws_subnet.private.*.id
    security_group_ids = [aws_security_group.vpc_endpoint.id]
  }

  environment {
    variables = {
      ENVIRONMENT = var.api_config.stage_name
    }
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.data_processor.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.private.execution_arn}/*/*"
}





# custom Lambda Authorizer

resource "aws_lambda_function" "custom_authorizer" {
  filename      = "authorizer.zip"
  function_name = "api-custom-authorizer"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.handler"
  runtime       = "nodejs14.x"
}

resource "aws_api_gateway_authorizer" "custom" {
  name                   = "custom-authorizer"
  rest_api_id            = aws_api_gateway_rest_api.private.id
  authorizer_uri         = aws_lambda_function.custom_authorizer.invoke_arn
  authorizer_credentials = aws_iam_role.apigw_lambda.arn
  type                   = "TOKEN"
}



# Method-level security

resource "aws_api_gateway_method" "secure_method" {
  for_each = {
    for method in local.api_methods : 
    "${method.resource_path}-${method.http_method}" => method 
    if method.integration_type == "CUSTOM_AUTH"
  }

  rest_api_id   = aws_api_gateway_rest_api.private.id
  resource_id   = aws_api_gateway_resource.resource[each.value.resource_path].id
  http_method   = each.value.http_method
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.custom.id
  
  request_parameters = {
    "method.request.header.Authorization" = true
  }
}

resource "aws_api_gateway_method" "oauth_method" {
  for_each = {
    for method in local.api_methods : 
    "${method.resource_path}-${method.http_method}" => method 
    if method.integration_type == "COGNITO_AUTH"
  }

  rest_api_id   = aws_api_gateway_rest_api.private.id
  resource_id   = aws_api_gateway_resource.resource[each.value.resource_path].id
  http_method   = each.value.http_method
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}





resource "aws_iam_role" "apigw_lambda" {
  name = "api-gw-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "apigateway.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "apigw_lambda" {
  role       = aws_iam_role.apigw_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayInvokeFullAccess"
}
