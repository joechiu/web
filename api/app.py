from flask import Flask, jsonify, request
from flask_cors import CORS

app = Flask(__name__)
CORS(app)  # allows your GitHub Pages site to call this API

@app.route("/")
def home():
    return jsonify({"message": "API is running"})

@app.route("/api/hello")
def hello():
    name = request.args.get("name", "World")
    return jsonify({"greeting": f"Hello, {name}!"})

@app.route("/api/echo", methods=["POST"])
def echo():
    data = request.get_json()
    return jsonify({"you_sent": data})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
