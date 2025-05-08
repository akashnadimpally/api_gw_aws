

resource "aws_iam_role" "lambda_role" {
  name               = "${local.lambda_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_policy_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_exec_role_basic_policy_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = data.aws_iam_policy.lambda_basic_exec.arn
}

resource "aws_lambda_function" "lambda" {
  architectures = ["x86_64"]
  filename      = "${path.module}/lambda/index.zip"
  function_name = local.lambda_function_name
  handler       = "index.handler"
  package_type  = "Zip"
  runtime       = "python3.9"
  role          = aws_iam_role.lambda_role.arn
}

