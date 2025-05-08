# example — keep it in the same Terraform run or create manually beforehand
resource "aws_iam_role" "apigw_s3_role" {
  name               = "apigw-s3-read-role"
  assume_role_policy = jsonencode({
    Version : "2012-10-17",
    Statement : [{
      Effect : "Allow",
      Principal : { Service : "apigateway.amazonaws.com" },
      Action : "sts:AssumeRole"
    }]
  })
}

data "aws_iam_policy_document" "apigw_s3_read" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::demo-web-bucket/*"]
    effect    = "Allow"
  }
}

resource "aws_iam_role_policy" "apigw_s3_attach" {
  role   = aws_iam_role.apigw_s3_role.id
  policy = data.aws_iam_policy_document.apigw_s3_read.json
}
