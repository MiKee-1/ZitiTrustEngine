import os
import sqlite3
import time

from flask import Flask, jsonify, request

app = Flask(__name__)
DB_PATH = "/data/historian.db"


def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        """CREATE TABLE IF NOT EXISTS requests (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL, remote_addr TEXT, method TEXT, path TEXT
        )"""
    )
    conn.execute(
        """CREATE TABLE IF NOT EXISTS readings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL, gateway TEXT, value REAL
        )"""
    )
    conn.commit()
    return conn


@app.before_request
def log_request():
    conn = get_db()
    conn.execute(
        "INSERT INTO requests (ts, remote_addr, method, path) VALUES (?, ?, ?, ?)",
        (time.time(), request.remote_addr, request.method, request.path),
    )
    conn.commit()
    conn.close()


@app.route("/health")
def health():
    return jsonify(status="ok", ts=time.time())


@app.route("/api/readings", methods=["GET", "POST"])
def readings():
    conn = get_db()
    if request.method == "POST":
        data = request.get_json(force=True, silent=True) or {}
        conn.execute(
            "INSERT INTO readings (ts, gateway, value) VALUES (?, ?, ?)",
            (time.time(), data.get("gateway", "unknown"), data.get("value", 0)),
        )
        conn.commit()
        conn.close()
        return jsonify(status="stored"), 201

    rows = conn.execute(
        "SELECT ts, gateway, value FROM readings ORDER BY id DESC LIMIT 20"
    ).fetchall()
    conn.close()
    return jsonify(readings=[{"ts": r[0], "gateway": r[1], "value": r[2]} for r in rows])


if __name__ == "__main__":
    os.makedirs("/data", exist_ok=True)
    get_db().close()
    app.run(host="0.0.0.0", port=5000)
