import json
import logging
import os
import random
import time
from datetime import datetime, timezone

from flask import Flask, jsonify
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

# LOGS — structured JSON to a file Promtail tails.
LOG_PATH = os.environ.get("APP_LOG_PATH", "/var/log/sample-app/app.log")
os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)


class JsonFormatter(logging.Formatter):
    def format(self, record):
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname.lower(),
            "msg": record.getMessage(),
            "service": "sample-app",
        }
        if hasattr(record, "extra_fields"):
            payload.update(record.extra_fields)
        return json.dumps(payload)


handler = logging.FileHandler(LOG_PATH)
handler.setFormatter(JsonFormatter())
log = logging.getLogger("sample-app")
log.setLevel(logging.INFO)
log.addHandler(handler)


def log_with(level, msg, **fields):
    rec = log.makeRecord(log.name, level, "", 0, msg, (), None)
    rec.extra_fields = fields
    log.handle(rec)


# METRICS — Prometheus client.
REQUESTS = Counter(
    "sample_service_requests_total",
    "Total HTTP requests",
    ["endpoint", "status"],
)
LATENCY = Histogram(
    "sample_service_request_duration_seconds",
    "Request duration",
    ["endpoint"],
)


app = Flask(__name__)


@app.route("/")
def index():
    REQUESTS.labels(endpoint="/", status="200").inc()
    return jsonify(status="ok")


@app.route("/work")
def work():
    start = time.time()
    time.sleep(random.uniform(0.01, 0.2))
    duration = time.time() - start
    LATENCY.labels(endpoint="/work").observe(duration)
    REQUESTS.labels(endpoint="/work", status="200").inc()
    log_with(logging.INFO, "work completed", duration_ms=round(duration * 1000, 2))
    return jsonify(duration_seconds=duration)


@app.route("/error")
def error():
    REQUESTS.labels(endpoint="/error", status="500").inc()
    log_with(logging.ERROR, "synthetic error path hit", request_id=str(random.randint(1000, 9999)))
    return jsonify(error="synthetic"), 500


@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


if __name__ == "__main__":
    log_with(logging.INFO, "sample-app starting", port=9000)
    app.run(host="0.0.0.0", port=9000)
