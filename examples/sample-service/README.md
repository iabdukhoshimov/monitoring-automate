# Sample Service — Monitoring Integration PoC

A 50-line Python service that demonstrates the three signal flows into the monitoring stack:

1. **Metrics** — exposed on `/metrics`, scraped by Prometheus
2. **Logs** — written as JSON, tailed by Alloy, pushed to Loki
3. **Alerts** — a `send-alert.sh` script demonstrates the direct event-service webhook path

> Tracing is not exercised here — the platform doesn't ship Tempo yet. See [`../../INTEGRATION.md`](../../INTEGRATION.md#4-traces--roadmap).

---

## Layout

```
sample-service/
├── README.md            # this file
├── docker-compose.yml   # app + alloy + loki + prometheus
├── app.py               # the service
├── requirements.txt
├── Dockerfile
├── alloy-config.alloy   # tails the app's log file → Loki
├── prometheus.yml       # scrapes the app
└── send-alert.sh        # POSTs an Alertmanager v4 webhook to event-service
```

---

## Run it

```bash
cd examples/sample-service
docker compose up --build
```

This starts:

| Service     | Port | What it does                                            |
| ----------- | ---- | ------------------------------------------------------- |
| sample-app  | 9000  | exposes `/`, `/work`, `/metrics`; logs JSON to a file  |
| alloy       | 12345 | tails `app.log`, ships to Loki                         |
| loki        | 3100  | log store                                              |
| prometheus  | 9090  | scrapes `sample-app:9000/metrics`                      |

Generate some traffic:

```bash
for i in $(seq 1 50); do curl -s http://localhost:9000/work > /dev/null; done
curl -s http://localhost:9000/error
```

Then open:

- Prometheus targets — http://localhost:9090/targets (sample-app should be `UP`)
- Prometheus query — http://localhost:9090/graph?g0.expr=sample_service_requests_total
- Loki via API — `curl -G -s "http://localhost:3100/loki/api/v1/query" --data-urlencode 'query={job="sample-app"}'`

In a real deployment you'd point this at the platform's Loki/Prometheus instead of running them locally.

---

## Send a direct alert

The `send-alert.sh` script POSTs an Alertmanager v4 webhook to event-service. By default it targets `http://localhost:8080/webhook` — set `EVENT_SERVICE_URL` to override:

```bash
EVENT_SERVICE_URL=http://event-service.internal:8080 ./send-alert.sh
```

This produces one message on Kafka topic `monitoring.alerts` with the alert fingerprint as the message key.

---

## What to copy into your real service

- The `prometheus_client` setup in `app.py` (lines marked `# METRICS`).
- The structured-logging pattern (`# LOGS`) — every log line is a single JSON object with `level`, `msg`, `timestamp`, plus arbitrary extra fields.
- `alloy-config.alloy` is the template for what to ask the platform team to wire into the `alloy` role for your host — typically via host_vars overriding `alloy_log_source: file` + `alloy_file_paths`, plus any `stage.json`/`stage.labels` blocks added to `roles/alloy/templates/config.alloy.j2`.
- The shape of `prometheus.yml`'s scrape job — translate to `prometheus_extra_scrape_configs` in your env's group_vars.

---

## What this PoC does **not** demonstrate

- Tracing (Tempo not deployed).
- Metric-derived alerts (those live in `roles/prometheus/templates/alerting_rules.yml.j2`, deployed by Ansible — they aren't service-side code).
- TLS / auth on the Loki push or webhook endpoints — production deployments should put these behind nginx + mTLS or an internal-only network.
