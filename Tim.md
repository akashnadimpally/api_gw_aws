openapi: 3.0.1
info:
  title: Example API (API Key)
  version: '1.0'
x-amazon-apigateway-endpoint-configuration:
  types:
    - PRIVATE
x-amazon-apigateway-stage: dev           # Custom extension to indicate stage name
security:
  - ApiKeyAuth: []                       # Require API Key for all operations
paths:
  /echo:
    get:
      summary: "Echo GET input"
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema:
                type: object
      x-amazon-apigateway-integration:
        type: aws_proxy
        httpMethod: POST
        uri: "arn:aws:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${stageVariables.LambdaArn}/invocations"
      x-amazon-apigateway-usage-plans:
        - name: Basic
          throttle:
            rateLimit: 5
            burstLimit: 5
          quota:
            period: MONTH
            limit: 1000
        - name: Premium
          throttle:
            rateLimit: 20
            burstLimit: 20
          quota:
            period: MONTH
            limit: 10000
    post:
      summary: "Echo POST input"
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema:
                type: object
      x-amazon-apigateway-integration:
        type: aws_proxy
        httpMethod: POST
        uri: "arn:aws:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${stageVariables.LambdaArn}/invocations"
      x-amazon-apigateway-usage-plans:
        - name: Basic
          throttle:
            rateLimit: 2
            burstLimit: 2
          quota:
            period: MONTH
            limit: 1000
        - name: Premium
          throttle:
            rateLimit: 10
            burstLimit: 10
          quota:
            period: MONTH
            limit: 10000
  /site:
    get:
      summary: "Get static site content"
      responses:
        '200':
          description: OK (HTML content)
          content:
            text/html:
              schema:
                type: string
      x-amazon-apigateway-integration:
        type: aws
        httpMethod: GET
        uri: "arn:aws:apigateway:${AWS::Region}:s3:path/${stageVariables.StaticBucketName}/index.html"
        credentials: "${stageVariables.S3RoleArn}"
        responses:
          "4\\d{2}":
            statusCode: "400"
          "5\\d{2}":
            statusCode: "500"
      x-amazon-apigateway-usage-plans:
        - name: Basic
          throttle:
            rateLimit: 2
            burstLimit: 2
          quota:
            period: MONTH
            limit: 1000
        - name: Premium
          throttle:
            rateLimit: 10
            burstLimit: 10
          quota:
            period: MONTH
            limit: 10000
components:
  securitySchemes:
    ApiKeyAuth:
      type: apiKey
      name: x-api-key
      in: header







# sigv4.yaml

openapi: 3.0.1
info:
  title: Example API (IAM Auth)
  version: '1.0'
x-amazon-apigateway-endpoint-configuration:
  types:
    - PRIVATE
x-amazon-apigateway-stage: dev
security:
  - Sigv4Auth: []                        # Require AWS IAM authentication
paths:
  /echo:
    get:
      summary: "Echo GET input"
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema:
                type: object
      x-amazon-apigateway-integration:
        type: aws_proxy
        httpMethod: POST
        uri: "arn:aws:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${stageVariables.LambdaArn}/invocations"
      x-amazon-apigateway-usage-plans:
        - name: Basic
          throttle:
            rateLimit: 5
            burstLimit: 5
          quota:
            period: MONTH
            limit: 1000
        - name: Premium
          throttle:
            rateLimit: 20
            burstLimit: 20
          quota:
            period: MONTH
            limit: 10000
    post:
      summary: "Echo POST input"
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema:
                type: object
      x-amazon-apigateway-integration:
        type: aws_proxy
        httpMethod: POST
        uri: "arn:aws:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${stageVariables.LambdaArn}/invocations"
      x-amazon-apigateway-usage-plans:
        - name: Basic
          throttle:
            rateLimit: 2
            burstLimit: 2
          quota:
            period: MONTH
            limit: 1000
        - name: Premium
          throttle:
            rateLimit: 10
            burstLimit: 10
          quota:
            period: MONTH
            limit: 10000
  /site:
    get:
      summary: "Get static site content"
      responses:
        '200':
          description: OK (HTML content)
          content:
            text/html:
              schema:
                type: string
      x-amazon-apigateway-integration:
        type: aws
        httpMethod: GET
        uri: "arn:aws:apigateway:${AWS::Region}:s3:path/${stageVariables.StaticBucketName}/index.html"
        credentials: "${stageVariables.S3RoleArn}"
        responses:
          "4\\d{2}":
            statusCode: "400"
          "5\\d{2}":
            statusCode: "500"
      x-amazon-apigateway-usage-plans:
        - name: Basic
          throttle:
            rateLimit: 2
            burstLimit: 2
          quota:
            period: MONTH
            limit: 1000
        - name: Premium
          throttle:
            rateLimit: 10
            burstLimit: 10
          quota:
            period: MONTH
            limit: 10000
components:
  securitySchemes:
    Sigv4Auth:
      type: apiKey
      name: Authorization
      in: header
      x-amazon-apigateway-authtype: awsSigv4


# index.py

import json

def lambda_handler(event, context):
    """Lambda function that echoes the request input."""
    # Prepare the response body with details from the event
    response_body = {
        "method": event.get("httpMethod"),
        "path": event.get("path"),
        "headers": event.get("headers"),
        "queryStringParameters": event.get("queryStringParameters"),
        "body": event.get("body")
    }
    return {
        "statusCode": 200,
        "headers": { "Content-Type": "application/json" },
        "body": json.dumps(response_body)
    }


# index.html

<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Static Site</title>
  <style>
    body { font-family: Arial, sans-serif; background: #f9f9f9; margin: 2em; }
    h1 { color: #3366cc; }
    p  { font-size: 1.1em; }
  </style>
  <script>
    console.log("Static site loaded.");
  </script>
</head>
<body>
  <h1>Welcome to the Static Website</h1>
  <p>This is a simple static HTML page served from an S3 bucket.</p>
  <p>You can access this page through the API Gateway or directly via the S3 website URL.</p>
</body>
</html>

