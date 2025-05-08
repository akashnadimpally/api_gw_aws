import json

def lambda_handler(event, context):
    """Lambda function that echoes the request input."""
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