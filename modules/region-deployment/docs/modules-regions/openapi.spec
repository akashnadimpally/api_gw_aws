openapi: 3.0.1
info:
  title: MRAP API
  version: 1.0.0
x-amazon-apigateway-policy:
  Version: "2012-10-17"
  Statement:
    - Effect: Allow
      Principal: "*"
      Action: "execute-api:Invoke"
      Resource: "execute-api:/*/*/*"
      Condition:
        StringEquals:
          aws:SourceVpce: ${vpce_ids}
paths:
  /lambda/{proxy+}:
    x-amazon-apigateway-any-method:
      parameters:
        - name: proxy
          in: path
          required: true
          schema:
            type: string
      x-amazon-apigateway-integration:
        uri: "arn:aws:apigateway:${region}:lambda:path/2015-03-31/functions/${lambda_arn}/invocations"
        httpMethod: POST
        type: aws_proxy

  /ecs/{proxy+}:
    x-amazon-apigateway-any-method:
      parameters:
        - name: proxy
          in: path
          required: true
          schema:
            type: string
      x-amazon-apigateway-integration:
        uri: "http://${nlb_dns}/ecs/{proxy}"
        httpMethod: ANY
        connectionType: VPC_LINK
        connectionId: "${vpc_link_id}"
        type: http_proxy

  /eks/{proxy+}:
    x-amazon-apigateway-any-method:
      parameters:
        - name: proxy
          in: path
          required: true
          schema:
            type: string
      x-amazon-apigateway-integration:
        uri: "http://${nlb_dns}/eks/{proxy}"
        httpMethod: ANY
        connectionType: VPC_LINK
        connectionId: "${vpc_link_id}"
        type: http_proxy
