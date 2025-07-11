from flask import Flask, request, jsonify
import json
import base64
from urllib.parse import parse_qs

app = Flask(__name__)

# Flask routes for local development
@app.route('/hello', methods=['GET'])
def hello():
    name = request.args.get('name', 'World')
    return jsonify({"message": f"Hello, {name}!"})

@app.route('/add', methods=['GET'])
def add():
    try:
        a = int(request.args.get('a'))
        b = int(request.args.get('b'))
        return jsonify({"result": a + b})
    except (TypeError, ValueError):
        return jsonify({"error": "Both 'a' and 'b' parameters are required and must be integers"}), 400

@app.route('/reverse', methods=['POST'])
def reverse_text():
    try:
        # Handle both form data and JSON
        if request.is_json:
            data = request.get_json()
            text = data.get('text')
        else:
            text = request.form.get('text') or request.args.get('text')
        
        if not text:
            return jsonify({"error": "Text parameter is required"}), 400
            
        return jsonify({"reversed": text[::-1]})
    except Exception as e:
        return jsonify({"error": str(e)}), 400

@app.route('/status', methods=['GET'])
def status():
    return jsonify({"status": "ok"})

@app.route('/lambda/<path:path>', methods=['GET'])
def catch_all_path(path):
    return jsonify({"path": path})

# Helper function to parse request body
def parse_request_body(event):
    """Parse request body from Lambda event"""
    body = event.get('body', '')
    if not body:
        return {}
    
    # Handle base64 encoded body
    if event.get('isBase64Encoded', False):
        body = base64.b64decode(body).decode('utf-8')
    
    # Try to parse as JSON
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        # Try to parse as form data
        try:
            return dict(parse_qs(body))
        except:
            return {'text': body}

# AWS Lambda handler function (without awsgi)
def lambda_handler(event, context):
    """
    AWS Lambda handler function - Pure Python implementation
    """
    try:
        # Extract request info from Lambda event
        method = event.get('httpMethod', 'GET')
        path = event.get('path', '/')
        query_params = event.get('queryStringParameters') or {}
        headers = event.get('headers', {})
        
        # Handle different routes
        if path == '/hello':
            name = query_params.get('name', 'World')
            return {
                'statusCode': 200,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({"message": f"Hello, {name}!"})
            }
        
        elif path == '/add':
            try:
                a = int(query_params.get('a', 0))
                b = int(query_params.get('b', 0))
                return {
                    'statusCode': 200,
                    'headers': {
                        'Content-Type': 'application/json',
                        'Access-Control-Allow-Origin': '*'
                    },
                    'body': json.dumps({"result": a + b})
                }
            except (TypeError, ValueError):
                return {
                    'statusCode': 400,
                    'headers': {
                        'Content-Type': 'application/json',
                        'Access-Control-Allow-Origin': '*'
                    },
                    'body': json.dumps({"error": "Both 'a' and 'b' parameters are required and must be integers"})
                }
        
        elif path == '/reverse' and method == 'POST':
            try:
                # Parse request body
                body_data = parse_request_body(event)
                text = body_data.get('text', '')
                
                # Also check query parameters as fallback
                if not text:
                    text = query_params.get('text', '')
                
                if not text:
                    return {
                        'statusCode': 400,
                        'headers': {
                            'Content-Type': 'application/json',
                            'Access-Control-Allow-Origin': '*'
                        },
                        'body': json.dumps({"error": "Text parameter is required"})
                    }
                
                return {
                    'statusCode': 200,
                    'headers': {
                        'Content-Type': 'application/json',
                        'Access-Control-Allow-Origin': '*'
                    },
                    'body': json.dumps({"reversed": text[::-1]})
                }
            except Exception as e:
                return {
                    'statusCode': 400,
                    'headers': {
                        'Content-Type': 'application/json',
                        'Access-Control-Allow-Origin': '*'
                    },
                    'body': json.dumps({"error": str(e)})
                }
        
        elif path == '/status':
            return {
                'statusCode': 200,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({"status": "ok"})
            }
        
        elif path.startswith('/lambda/'):
            # Extract the path after /lambda/
            extracted_path = path[8:]  # Remove '/lambda/' prefix
            return {
                'statusCode': 200,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({"path": extracted_path})
            }
        
        else:
            # 404 Not Found
            return {
                'statusCode': 404,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({"error": "Not found", "path": path})
            }
    
    except Exception as e:
        # Handle any unexpected errors
        return {
            'statusCode': 500,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({"error": f"Internal server error: {str(e)}"})
        }

# For local development and testing
if __name__ == '__main__':
    print("Starting Flask development server...")
    print("Available endpoints:")
    print("  GET  /hello?name=YourName")
    print("  GET  /add?a=5&b=3")
    print("  POST /reverse (with JSON: {'text': 'hello'})")
    print("  GET  /status")
    print("  GET  /lambda/any/path")
    print("\nStarting server on http://localhost:5000")
    app.run(debug=True, host='0.0.0.0', port=5000)
