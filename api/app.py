import os
from flask import Flask, jsonify, request
from flask_cors import CORS
from supabase import create_client, Client

app = Flask(__name__)
CORS(app)

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY")

supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

@app.route("/")
def home():
    return jsonify({"message": "API is running"})


@app.route("/api/items", methods=["GET"])
def get_items():
    try:
        response = supabase.table("items").select("*").order("created", desc=True).execute()
        return jsonify(response.data)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/items", methods=["POST"])
def add_item():
    try:
        data = request.get_json()
        name = data.get("name")
        note = data.get("note")

        if not name:
            return jsonify({"error": "name is required"}), 400

        response = supabase.table("items").insert({
            "name": name,
            "note": note
        }).execute()

        return jsonify(response.data), 201
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000)
