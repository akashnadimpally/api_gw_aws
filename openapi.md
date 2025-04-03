Here's a comprehensive solution with OpenAPI spec, Lambda code, and S3 static website content:

### 1. Complete OpenAPI Specification (`openapi-spec.yaml`)
```yaml
openapi: 3.0.3
info:
  title: Full-Stack API Gateway
  version: 2.1.0
  description: |
    Comprehensive API with versioned endpoints, Lambda integration, 
    and S3 static hosting with full HTTP method support

x-amazon-apigateway-request-validators:
  all:
    validateRequestBody: true
    validateRequestParameters: true

x-amazon-apigateway-request-validator: all

x-amazon-apigateway-usage-plans:
  - name: "free-tier"
    throttle:
      burstLimit: 50
      rateLimit: 25
    quota:
      limit: 5000
      period: DAY
  - name: "enterprise"
    throttle:
      burstLimit: 1000
      rateLimit: 500
    quota:
      limit: 100000
      period: MONTH

paths:
  /api/v1/data:
    get:
      x-amazon-apigateway-integration:
        type: aws_proxy
        httpMethod: POST
        uri: "arn:aws:apigateway:${region}:lambda:path/2015-03-31/functions/${data_lambda_arn}/invocations"
      responses:
        '200':
          description: Data retrieved
    post:
      x-amazon-apigateway-integration:
        type: aws_proxy
        httpMethod: POST
        uri: "arn:aws:apigateway:${region}:lambda:path/2015-03-31/functions/${data_lambda_arn}/invocations"
      requestBody:
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/DataRequest'
      responses:
        '201':
          description: Data created

  /api/v2/users/{user_id}:
    get:
      parameters:
        - name: user_id
          in: path
          required: true
          schema:
            type: string
      x-amazon-apigateway-integration:
        type: aws_proxy
        httpMethod: POST
        uri: "arn:aws:apigateway:${region}:lambda:path/2015-03-31/functions/${users_lambda_arn}/invocations"
      responses:
        '200':
          description: User data retrieved
    put:
      parameters:
        - name: user_id
          in: path
          required: true
          schema:
            type: string
      x-amazon-apigateway-integration:
        type: aws_proxy
        httpMethod: POST
        uri: "arn:aws:apigateway:${region}:lambda:path/2015-03-31/functions/${users_lambda_arn}/invocations"
      requestBody:
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/User'
      responses:
        '200':
          description: User updated
    delete:
      parameters:
        - name: user_id
          in: path
          required: true
          schema:
            type: string
      x-amazon-apigateway-integration:
        type: aws_proxy
        httpMethod: POST
        uri: "arn:aws:apigateway:${region}:lambda:path/2015-03-31/functions/${users_lambda_arn}/invocations"
      responses:
        '204':
          description: User deleted

  /static/{proxy+}:
    get:
      parameters:
        - name: proxy
          in: path
          required: true
          schema:
            type: string
      x-amazon-apigateway-integration:
        type: aws
        httpMethod: GET
        credentials: "${s3_role_arn}"
        uri: "arn:aws:apigateway:${region}:s3:path/${s3_bucket}/{proxy}"
        passthroughBehavior: when_no_match
      responses:
        '200':
          description: Static content served

components:
  securitySchemes:
    api-key:
      type: apiKey
      name: x-api-key
      in: header
      x-amazon-apigateway-usage-plans:
        - "free-tier"
        - "enterprise"
    jwt:
      type: http
      scheme: bearer
      bearerFormat: JWT

  schemas:
    DataRequest:
      type: object
      properties:
        payload:
          type: string
      required: [payload]
    User:
      type: object
      properties:
        name:
          type: string
        email:
          type: string
          format: email
      required: [name, email]

security:
  - api-key: []
  - jwt: []
```

### 2. Lambda Function Code (`lambda_handler.py`)
```python
import json
from datetime import datetime

def lambda_handler(event, context):
    method = event['httpMethod']
    path = event['path']
    
    response = {
        'statusCode': 200,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*'
        }
    }

    try:
        # API Version 1 - Data Endpoints
        if path.startswith('/api/v1/data'):
            if method == 'GET':
                response['body'] = json.dumps({
                    'data': [
                        {'id': 1, 'content': 'Sample Data 1'},
                        {'id': 2, 'content': 'Sample Data 2'}
                    ],
                    'timestamp': datetime.now().isoformat()
                })
            elif method == 'POST':
                body = json.loads(event['body'])
                response['body'] = json.dumps({
                    'message': 'Data created successfully',
                    'id': 123,
                    'received': body
                })
                response['statusCode'] = 201

        # API Version 2 - User Endpoints
        elif path.startswith('/api/v2/users'):
            user_id = path.split('/')[-1]
            
            if method == 'GET':
                response['body'] = json.dumps({
                    'id': user_id,
                    'name': 'John Doe',
                    'email': 'john@example.com'
                })
            elif method == 'PUT':
                body = json.loads(event['body'])
                response['body'] = json.dumps({
                    'message': 'User updated',
                    'id': user_id,
                    'updates': body
                })
            elif method == 'DELETE':
                response['body'] = json.dumps({'message': 'User deleted'})
                response['statusCode'] = 204

        else:
            response['statusCode'] = 404
            response['body'] = json.dumps({'error': 'Endpoint not found'})

    except Exception as e:
        response['statusCode'] = 500
        response['body'] = json.dumps({'error': str(e)})

    return response
```

### 3. S3 Static Website Content

**index.html**
```html
<!DOCTYPE html>
<html>
<head>
    <title>API Demo</title>
    <link rel="stylesheet" href="/static/styles.css">
</head>
<body>
    <h1>API Gateway Demo</h1>
    <div id="app">
        <button onclick="fetchData()">Load Data</button>
        <div id="output"></div>
    </div>
    <script src="/static/app.js"></script>
</body>
</html>
```

**styles.css**
```css
body {
    font-family: Arial, sans-serif;
    max-width: 800px;
    margin: 0 auto;
    padding: 20px;
}

button {
    padding: 10px 20px;
    background: #007bff;
    color: white;
    border: none;
    border-radius: 4px;
    cursor: pointer;
}

#output {
    margin-top: 20px;
    padding: 15px;
    border: 1px solid #ddd;
}
```

**app.js**
```javascript
const API_BASE = 'https://your-api-id.execute-api.region.amazonaws.com/prod';
const API_KEY = 'your-api-key';

async function fetchData() {
    try {
        const response = await fetch(`${API_BASE}/api/v1/data`, {
            headers: {
                'x-api-key': API_KEY
            }
        });
        
        const data = await response.json();
        document.getElementById('output').innerHTML = 
            `<pre>${JSON.stringify(data, null, 2)}</pre>`;
    } catch (error) {
        console.error('Error:', error);
    }
}
```

### 4. Deployment Instructions

1. **Package Lambda Function**:
```bash
zip -r lambda.zip lambda_handler.py
```

2. **Upload Static Content to S3**:
```bash
aws s3 sync ./static s3://your-bucket/static --acl public-read
```

3. **Terraform Variables**:
```terraform
variable "region" {
  default = "us-east-1"
}

variable "s3_bucket" {
  default = "your-static-bucket"
}

variable "data_lambda_arn" {
  default = "arn:aws:lambda:us-east-1:123456789012:function:data-handler"
}

variable "users_lambda_arn" {
  default = "arn:aws:lambda:us-east-1:123456789012:function:users-handler"
}
```

4. **Test Endpoints**:
```bash
# Get data
curl -H "x-api-key: your-key" https://your-api-id.execute-api.region.amazonaws.com/prod/api/v1/data

# Create data
curl -X POST -H "Content-Type: application/json" -H "x-api-key: your-key" \
  -d '{"payload":"test"}' https://your-api-id.execute-api.region.amazonaws.com/prod/api/v1/data
```

This solution provides:
- Versioned API endpoints
- Full CRUD operations
- Secure static content delivery
- Comprehensive request validation
- Usage plan enforcement
- Clean separation between API versions
- Sample frontend/backend integration

The Lambda handler supports:
- Multiple HTTP methods
- Path parameter parsing
- Error handling
- CORS support
- JSON request/response handling
