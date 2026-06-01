# Integration Guide — Monitoring Stack

How a client service plugs into this monitoring platform to ship **metrics**, **logs**, and **alerts** (and where traces fit on the roadmap).

This document is for service owners outside the platform team. If you operate the stack itself, see the main [README.md](README.md).

---

## What the platform provides

```
                       ┌───────────────────────────┐
   your service ──▶    │  metrics   →  Prometheus  │  :9090   pull /metrics
                       │  logs      →  Loki        │  :3100   push /loki/api/v1/push
                       │  alerts    →  Alertmanager│  :9093   (auto from Prometheus rules)
                       │            ↳  event-svc   │  :8080   /webhook → Kafka
                       │  traces    →  (roadmap)   │  Tempo + OTLP, not deployed yet
                       └─────────────┬─────────────┘
                                     ▼
                                 Grafana :3000
                          (dashboards & log explore)
```

| Signal  | Component       | Transport            | Mode  | Status     |
| ------- | --------------- | -------------------- | ----- | ---------- |
| Metrics | Prometheus      | HTTP `/metrics`      | pull  | ✅ live    |
| Logs    | Loki + Alloy    | `/loki/api/v1/push`  | push  | ✅ live    |
| Alerts  | Alertmanager    | rules → event-svc    | event | ✅ live    |
| Alerts (direct) | event-service `/webhook` | Alertmanager v4 JSON | push | ✅ live |
| Traces  | _Tempo (planned)_ | OTLP gRPC/HTTP     | push  | ⏳ roadmap |

The **`monitoring-event-service`** (sibling repo at `../monitoring-event-service`) is the egress bridge: every alert that fires lands as a JSON message on the Kafka topic `monitoring.alerts`, partitioned by alert fingerprint. Downstream consumers (your incident tooling, ticketing, chat bridge, custom logic) subscribe there — the platform deliberately does **not** couple to Slack/Telegram/email itself.

---

## 1. Metrics — expose, don't push

Prometheus pulls metrics from your service every 15s (prod/staging) or 30s (dev).

### What you do

1. **Expose `/metrics`** on an HTTP port using a Prometheus client library:
   - Go: [`prometheus/client_golang`](https://github.com/prometheus/client_golang)
   - Python: [`prometheus_client`](https://github.com/prometheus/client_python)
   - Node: [`prom-client`](https://github.com/siimon/prom-client)
   - Java: [`micrometer`](https://micrometer.io/) or `simpleclient`

2. **Tell the platform team where to scrape.** Open a PR that adds a job under `inventories/<env>/group_vars/prometheus/main.yml`:

```yaml
prometheus_extra_scrape_configs:
  - job_name: my-service
    metrics_path: /metrics
    scrape_interval: 15s
    static_configs:
      - targets:
          - my-service-1.internal:9000
          - my-service-2.internal:9000
        labels:
          service: my-service
          team: payments
          env: production
```

### Naming conventions

- Use snake_case: `http_requests_total`, `db_query_duration_seconds`.
- Include unit suffix: `_seconds`, `_bytes`, `_total` (counters).
- Prefix with service name to avoid collisions: `mysvc_orders_processed_total`.
- Keep label cardinality bounded — never label by `user_id`, `request_id`, or full URLs.

### Want alerts on these metrics?

Open a PR to `roles/prometheus/templates/alerting_rules.yml.j2` with a new group. Existing groups (`instance_health`, `node_resources`, `blackbox_probes`, `prometheus_health`) are good models. The alert will flow through Alertmanager → event-service → Kafka automatically, no extra wiring.

---

## 2. Logs — push to Loki

Two supported paths. Pick whichever fits your deployment.

### Option A — Grafana Alloy ships container or file logs (recommended for VMs / bare metal)

Run Grafana Alloy next to your service. Alloy is the supported successor to Promtail (which is EOL as of March 2026). It either tails files or discovers Docker container logs and pushes to Loki.

**Containerised service** (default): your service runs as a Docker container on a
host in the `[alloy]` inventory group. Alloy auto-discovers it via the Docker
socket. The container's `service_name` label (set automatically from the
`com.docker.compose.service` label) becomes a Loki stream label.

**File-based service**: ask the platform team to add the host to `[alloy]` and
override the log source in that host's group_vars (or inventory host_vars):

```yaml
# inventories/<env>/group_vars/alloy/main.yml  (or host_vars/<host>.yml)
alloy_log_source: file
alloy_file_paths:
  - /var/log/myservice/*.log
alloy_external_labels:
  service: my-service
  env: production
```

For structured pipelines (JSON parsing, label extraction), extend the
`loki.process` block in `roles/alloy/templates/config.alloy.j2` with `stage.json`
and `stage.labels` blocks — the Alloy component reference is at
`https://grafana.com/docs/alloy/latest/reference/components/loki/loki.process/`.

### Option B — Push directly via HTTP (recommended for containers / serverless)

For services where you can't run Alloy next to them (Lambda, Cloud Run, sidecar-less containers), push directly to Loki's HTTP API:

```
POST http://loki.internal:3100/loki/api/v1/push
Content-Type: application/json

{
  "streams": [
    {
      "stream": { "service": "my-service", "level": "error", "env": "production" },
      "values": [
        ["1714992000000000000", "{\"msg\":\"db timeout\",\"trace_id\":\"abc123\"}"]
      ]
    }
  ]
}
```

Timestamps are nanoseconds since epoch. Keep label keys low-cardinality (`service`, `env`, `level`) and put high-cardinality fields like `request_id` / `user_id` inside the log line, not in stream labels — Loki indexes labels, not message bodies.

### Querying

In Grafana → **Explore** → datasource **Loki**:

```logql
{service="my-service", level="error"} |= "timeout"
```

---

## 3. Alerts — derived, with a direct push escape hatch

### Default path: Prometheus rule → Alertmanager → event-service → Kafka

Most alerts should be **derived from metrics** via a Prometheus rule (see "Want alerts on these metrics?" above). This gives you grouping, deduplication, silencing, and a consistent payload shape for free.

### Direct webhook path (for one-off events)

If your service detects a condition that isn't observable as a metric — e.g., "third-party payment provider returned a malformed response" — POST directly to `event-service`:

```bash
curl -X POST http://event-service.internal:8080/webhook \
  -H "Content-Type: application/json" \
  -d '{
    "version": "4",
    "status": "firing",
    "receiver": "my-service",
    "groupLabels": {"alertname": "PaymentProviderMalformedResponse"},
    "commonLabels": {
      "alertname": "PaymentProviderMalformedResponse",
      "severity": "warning",
      "service": "my-service",
      "env": "production"
    },
    "commonAnnotations": {
      "summary": "Provider returned non-JSON",
      "description": "3 occurrences in the last minute"
    },
    "externalURL": "",
    "alerts": [{
      "status": "firing",
      "labels": {
        "alertname": "PaymentProviderMalformedResponse",
        "severity": "warning",
        "service": "my-service",
        "env": "production"
      },
      "annotations": {
        "summary": "Provider returned non-JSON",
        "description": "stripe-eu-1, http 200, body not parseable"
      },
      "startsAt": "2026-05-07T12:00:00Z",
      "endsAt": "0001-01-01T00:00:00Z",
      "fingerprint": "myservice-stripe-malformed-eu-1"
    }]
  }'
```

The payload must conform to **Alertmanager v4 webhook format** — see [`monitoring-event-service/README.md`](../monitoring-event-service/README.md) for the full schema. Each alert in the `alerts` array becomes one Kafka message keyed by `fingerprint`.

**Use the direct path sparingly.** Prefer metric-derived alerts so the same rule logic is visible in Prometheus and recoverable from history.

### Consuming alerts on the other end

Subscribe to Kafka topic `monitoring.alerts`. Each message is one alert as JSON:

```json
{
  "id": "a1b2c3d4e5f6",
  "status": "firing",
  "alertName": "HighMemoryUsage",
  "severity": "critical",
  "instance": "host1:9100",
  "job": "node-exporter",
  "summary": "Memory usage above 90%",
  "description": "Host host1 memory is at 92%",
  "labels": { "...": "..." },
  "annotations": { "...": "..." },
  "startsAt": "2026-05-07T10:00:00Z",
  "endsAt": "0001-01-01T00:00:00Z",
  "generatorURL": "http://prometheus:9090/graph?...",
  "receivedAt": "2026-05-07T10:00:05.123Z"
}
```

Idempotency note: Alertmanager retries on failure, so consumers must dedupe by `id` (= alert fingerprint).

---

## 4. Traces — roadmap

Tracing is **not yet deployed**. The proposed shape:

- Add a `tempo` role deploying [Grafana Tempo](https://grafana.com/oss/tempo/) (single-binary mode, S3 / local backend).
- Expose OTLP gRPC `:4317` and OTLP HTTP `:4318`.
- Provision Tempo as a Grafana datasource alongside Prometheus and Loki.
- Wire trace ↔ log correlation: emit `trace_id` in your log lines, configure Loki's `derivedFields` to link to Tempo.

**What you can do now to be ready:**
- Instrument with OpenTelemetry SDK in your language. Default exporter to OTLP. Set the endpoint via env var (`OTEL_EXPORTER_OTLP_ENDPOINT`) — when Tempo lands you flip a single config value.
- Always include `trace_id` in structured logs. Even before Tempo, that gives you correlatable log clusters in Loki.

If you need traces sooner, open an issue / talk to the platform team — adding a Tempo role is straightforward (~1 day of work).

---

## 5. PoC

A minimal, runnable example demonstrating metrics + logs + a manual alert push lives in [`examples/sample-service/`](examples/sample-service/). Spin it up with `docker compose up` and you'll have:

- a Python service emitting Prometheus metrics on `:9000/metrics`
- structured JSON logs tailed by Alloy and pushed to Loki
- a `send-alert.sh` script demonstrating the direct webhook path

See [`examples/sample-service/README.md`](examples/sample-service/README.md).

---

## Checklist for onboarding a new service

- [ ] Metrics endpoint at `/metrics` exposed and scraped (`prometheus_extra_scrape_configs`)
- [ ] Logs structured (JSON preferred), shipped to Loki via Alloy or direct push
- [ ] Stream labels kept low-cardinality (`service`, `env`, `level`)
- [ ] At least one Prometheus alert rule for the service (covers SLO breach or hard error rate)
- [ ] Grafana dashboard for the service (start by cloning Node Exporter Full's structure)
- [ ] On-call consumes from Kafka topic `monitoring.alerts` and routes by `severity` / `service` label
- [ ] (When ready) OpenTelemetry SDK wired with OTLP exporter, `trace_id` in logs

---

## Related

- Stack deployment: [README.md](README.md)
- Event service internals: [`../monitoring-event-service/README.md`](../monitoring-event-service/README.md)
- Alert rules in source: [`roles/prometheus/templates/alerting_rules.yml.j2`](roles/prometheus/templates/alerting_rules.yml.j2)
- Alertmanager routing: [`roles/alertmanager/templates/alertmanager.yml.j2`](roles/alertmanager/templates/alertmanager.yml.j2)
