resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

resource "aws_api_gateway_request_validator" "lambda" {
  name                  = "lambda-validator"
  rest_api_id           = aws_api_gateway_rest_api.main.id
  validate_request_body = true
}
