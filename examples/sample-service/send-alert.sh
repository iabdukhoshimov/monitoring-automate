#!/usr/bin/env bash
# Demonstrate the direct webhook path: POST an Alertmanager v4 payload to event-service.
# Each alert in `alerts[]` becomes one Kafka message keyed by `fingerprint`.

set -euo pipefail

EVENT_SERVICE_URL="${EVENT_SERVICE_URL:-http://localhost:8080}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FINGERPRINT="sample-app-synthetic-$(date +%s)"

curl -sS -X POST "${EVENT_SERVICE_URL}/webhook" \
  -H "Content-Type: application/json" \
  -d @- <<EOF
{
  "version": "4",
  "groupKey": "{}:{alertname=\"SampleAppSyntheticAlert\"}",
  "truncatedAlerts": 0,
  "status": "firing",
  "receiver": "sample-app",
  "groupLabels": { "alertname": "SampleAppSyntheticAlert" },
  "commonLabels": {
    "alertname": "SampleAppSyntheticAlert",
    "severity": "warning",
    "service": "sample-app",
    "env": "dev"
  },
  "commonAnnotations": {
    "summary": "Synthetic alert from PoC",
    "description": "Triggered by send-alert.sh"
  },
  "externalURL": "",
  "alerts": [{
    "status": "firing",
    "labels": {
      "alertname": "SampleAppSyntheticAlert",
      "severity": "warning",
      "service": "sample-app",
      "env": "dev",
      "instance": "sample-app:9000"
    },
    "annotations": {
      "summary": "Synthetic alert from PoC",
      "description": "Demonstrates direct webhook path to event-service"
    },
    "startsAt": "${NOW}",
    "endsAt": "0001-01-01T00:00:00Z",
    "generatorURL": "",
    "fingerprint": "${FINGERPRINT}"
  }]
}
EOF

echo
echo "Posted alert with fingerprint=${FINGERPRINT} to ${EVENT_SERVICE_URL}/webhook"
