from flask import Flask, request, jsonify
import json

app = Flask(__name__)

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

# AWS Lambda handler function
def lambda_handler(event, context):
    """
    AWS Lambda handler function
    """
    try:
        # Import awsgi here to avoid import errors in local development
        from awsgi import response
        
        # Handle the request using awsgi
        return response(app, event, context)
    except ImportError:
        # Fallback for local development
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'awsgi not available - this should run in AWS Lambda'})
        }

# For local development
if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5000)
