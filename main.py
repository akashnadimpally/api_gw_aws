from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route("/hello", methods=["GET"])
def hello():
    name = request.args.get("name", "World")
    return jsonify({"message": f"Hello, {name}!"})

@app.route("/add", methods=["GET"])
def add():
    a = int(request.args["a"])
    b = int(request.args["b"])
    return jsonify({"result": a + b})

@app.route("/reverse", methods=["POST"])
def reverse_text():
    # Changed from GET to POST with form data
    text = request.form["text"]
    return jsonify({"reversed": text[::-1]})

@app.route("/status", methods=["GET"])
def status():
    return jsonify({"status": "ok"})

@app.route("/lambda/<path:path>", methods=["GET"])
def catch_all_path(path):
    return jsonify({"path": path})

# AWS Lambda handler
from mangum import Mangum
handler = Mangum(app)

# Local entry point for testing
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
