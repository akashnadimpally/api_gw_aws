resource "aws_cognito_user_pool" "main" {
  name = "api-user-pool"
  
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }
}

resource "aws_cognito_user_pool_client" "client" {
  name = "api-client"
  user_pool_id = aws_cognito_user_pool.main.id
  generate_secret = true
  allowed_oauth_flows = ["code", "implicit"]
  allowed_oauth_scopes = ["email", "openid"]
  callback_urls = ["https://your-domain.com/callback"]
}

resource "aws_api_gateway_authorizer" "cognito" {
  name          = "cognito-authorizer"
  rest_api_id   = aws_api_gateway_rest_api.private.id
  type          = "COGNITO_USER_POOLS"
  provider_arns = [aws_cognito_user_pool.main.arn]
}
