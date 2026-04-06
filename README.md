# Ansible Monitoring Stack

Production-grade, idempotent Ansible automation for a complete open-source monitoring pipeline.
Deploys on **Rocky Linux 9 / RHEL / CentOS** and **Ubuntu 22.04 / Debian** — x86_64 and arm64.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          MONITORED INFRASTRUCTURE                           │
│                                                                             │
│   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐                  │
│   │ node_exporter│   │ node_exporter│   │ node_exporter│  :9100 (each host)│
│   │  :9100       │   │  :9100       │   │  :9100       │                  │
│   └──────┬───────┘   └──────┬───────┘   └──────┬───────┘                  │
└──────────┼─────────────────┼─────────────────┼────────────────────────────┘
           │  scrape /metrics│                 │
           └────────┬────────┘─────────────────┘
                    │ every 15s
                    ▼
┌───────────────────────────────────────────────────────────────┐
│  PROMETHEUS  :9090                                            │
│                                                               │
│  ┌─────────────────┐  ┌─────────────────┐                    │
│  │  scrape_configs  │  │  alerting_rules  │  25 rules         │
│  │  + relabeling    │  │  recording_rules │  9 agg rules      │
│  └─────────────────┘  └────────┬────────┘                    │
│                                │ fires alerts                 │
└────────────────────────────────┼──────────────────────────────┘
                                 │
             ┌───────────────────┘
             │ POST /api/v2/alerts
             ▼
┌────────────────────────────────┐
│  ALERTMANAGER  :9093           │
│                                │
│  group_by: alertname,          │
│    instance, severity          │
│  group_wait:  30s              │
│  group_interval: 5m            │
│  repeat_interval: 4h           │
│                                │
│  receiver: event-service       │
└──────────────┬─────────────────┘
               │ POST /webhook  (send_resolved: true)
               ▼
┌──────────────────────────────────────────────────────────────┐
│  EVENT SERVICE  :8080  (Go)                                  │
│                                                              │
│  • Receives Alertmanager webhook payload                     │
│  • Normalizes to AlertEvent schema                           │
│  • Produces to Kafka topic: monitoring.alerts                │
└──────────────────────────────┬───────────────────────────────┘
                               │ Kafka produce
                               ▼
┌──────────────────────────────────────────────────────────────┐
│  CLIENT'S KAFKA  (kafka-1,2,3.internal:9092)                 │
│  topic: monitoring.alerts                                    │
│                                                              │
│  Client consumes and routes through their own system —       │
│  no duplicate alerting pipelines, no Telegram/Slack/email    │
│  coupling on this side.                                      │
└──────────────────────────────────────────────────────────────┘


┌─────────────────────────────────────────────────────────────────────────────┐
│  BLACKBOX EXPORTER  :9115                                                   │
│                                                                             │
│  ◄── Prometheus scrapes /probe?target=...&module=...                        │
│                                                                             │
│  Modules:  http_2xx · tcp_connect · icmp                                   │
│  Checks:   HTTP status · response time · SSL cert expiry · TCP port open    │
└─────────────────────────────────────────────────────────────────────────────┘


┌─────────────────────────────────────────────────────────────────────────────┐
│  GRAFANA  :3000                                                             │
│                                                                             │
│  Datasources (provisioned via API):                                         │
│    ├── Prometheus  :9090  (default, HTTP POST)                              │
│    └── Elasticsearch  :9200  (logs)                                        │
│                                                                             │
│  Dashboards (auto-imported by UID, skip if already present):               │
│    ├── Node Exporter Full   #1860 rev37                                    │
│    ├── Blackbox Exporter    #7587 rev3                                     │
│    └── Prometheus Stats     #2    rev2                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## What This Deploys

| Component | Version | Port | Purpose |
|---|---|---|---|
| Prometheus | 2.51.0 | 9090 | Metrics collection, alert rules, recording rules |
| Alertmanager | 0.27.0 | 9093 | Alert grouping and webhook forwarding to event service |
| Grafana | 10.4.0 | 3000 | Dashboards — provisioned datasources + auto-imported |
| Node Exporter | 1.8.1 | 9100 | Host metrics (CPU, memory, disk, network, systemd) |
| Blackbox Exporter | 0.25.0 | 9115 | HTTP/TCP/ICMP probing, SSL cert expiry checks |
| Event Service | 1.0.0 | 8080 | Webhook → Kafka bridge (Go service, deployed separately) |

Every component runs as a dedicated non-root system user, managed by systemd, with firewall rules hardened to the minimum required ports.

---

## Features

- **Idempotent** — safe to re-run at any time; existing state is preserved
- **Dual OS support** — Rocky Linux 9 / RHEL / CentOS and Ubuntu 22.04 / Debian
- **Dual architecture** — x86_64 (amd64) and arm64 checksums for all binaries
- **Modular roles** — one role per component; deploy individually or as a full stack
- **Version-pinned with checksums** — every binary SHA256-verified before install
- **Selective collectors** — Node Exporter enables only the collectors you need (cpu, meminfo, diskstats, filesystem, netdev, loadavg, uname, time, systemd) to keep cardinality low
- **Blackbox probing** — HTTP, TCP, and ICMP targets defined in `group_vars`; add endpoints without redeployment
- **25 alert rules** across four groups: instance health, node resources, blackbox probes, Prometheus self-health
- **Single webhook output** — Alertmanager forwards all alerts to the event service; no Telegram/Slack/email coupling
- **Grafana via API** — datasources and dashboards provisioned idempotently via the HTTP API; UID-checked before import to avoid duplicates
- **Ansible Vault** — secrets (Grafana admin password, secret key) encrypted at rest
- **Lint clean** — passes `ansible-lint --profile production` (0 failures across 106 files)
- **Molecule tested** — all 6 roles verified on Rocky Linux 9 + Ubuntu 22.04 in Docker

---

## Alert Rules

### Instance Health (`instance_health`)

| Alert | Condition | Severity |
|---|---|---|
| `InstanceDown` | `up == 0` for 2m | critical |
| `HighCpuUsage` | CPU > 85% for 5m | warning |
| `HighMemoryUsage` | Memory > 85% for 5m | warning |
| `DiskSpaceLow` | Available disk < 15% for 5m | warning |
| `DiskSpaceCritical` | Available disk < 5% for 2m | critical |

### Node Resources (`node_resources`)

| Alert | Condition | Severity |
|---|---|---|
| `NodeHighLoadAverage` | Load > 1.5× CPU count for 10m | warning |
| `NodeSwapUsageHigh` | Swap > 80% for 5m | warning |
| `NodeFileDescriptorExhaustion` | FD usage > 90% for 5m | warning |
| `NodeOOMKillDetected` | OOM kill detected in last 5m | critical |
| `NodeDiskIOSaturation` | Disk I/O > 90% utilized for 5m | warning |
| `NodeNetworkErrors` | rx+tx errors > 0 for 5m | warning |
| `NodeClockSkewDetected` | NTP offset > 50ms for 2m | warning |
| `NodeSystemdServiceFailed` | systemd unit in failed state for 2m | critical |

### Blackbox Probes (`blackbox_probes`)

| Alert | Condition | Severity |
|---|---|---|
| `ProbeFailed` | `probe_success == 0` for 2m | critical |
| `ProbeSlowHttp` | HTTP response > 2s for 5m | warning |
| `ProbeHttpStatusCode` | Status ≤ 199 or ≥ 400 for 2m | critical |
| `ProbeSslCertExpiringSoon` | SSL cert expires in < 14 days | warning |
| `ProbeSslCertExpiryImminent` | SSL cert expires in < 3 days | critical |

### Prometheus Self-Health (`prometheus_health`)

| Alert | Condition | Severity |
|---|---|---|
| `Watchdog` | Always fires — confirms pipeline is alive | none |
| `PrometheusConfigReloadFailed` | Last reload unsuccessful for 5m | critical |
| `AlertmanagerConfigReloadFailed` | Last reload unsuccessful for 5m | critical |
| `PrometheusRuleEvaluationFailures` | Rule eval failures > 0 for 5m | critical |
| `PrometheusTSDBCompactionsFailing` | TSDB compaction failures for 1h | warning |
| `AlertmanagerNotificationsFailing` | Notification failures > 0 for 5m | critical |
| `PrometheusTargetScrapeSlow` | Scrape duration > 10s for 5m | warning |

---

## Project Structure

```
.
├── ansible.cfg
├── site.yml                          # Full-stack entry point
├── requirements.yml                  # Collections: ansible.posix, community.general
├── molecule-requirements.txt         # molecule, molecule-plugins[docker], ansible-lint
├── playbooks/
│   ├── common.yml
│   ├── node_exporter.yml
│   ├── blackbox_exporter.yml
│   ├── prometheus.yml
│   ├── alertmanager.yml
│   ├── grafana.yml
│   └── grafana_api.yml               # Datasource + dashboard provisioning via HTTP API
├── roles/
│   ├── common/                       # OS prep, chrony, common packages
│   ├── prometheus/
│   │   └── templates/
│   │       ├── prometheus.yml.j2
│   │       ├── alerting_rules.yml.j2   # 25 alert rules
│   │       └── recording_rules.yml.j2  # 9 recording rules
│   ├── alertmanager/
│   │   └── templates/
│   │       └── alertmanager.yml.j2     # Single webhook receiver
│   ├── grafana/
│   ├── blackbox_exporter/
│   └── node_exporter/
└── inventories/
    ├── dev/                          # 7d retention · 30s scrape · 1 Kafka broker
    │   ├── hosts.ini
    │   └── group_vars/
    │       ├── all/          # vault.yml + main.yml (env: dev)
    │       ├── prometheus/
    │       ├── alertmanager/
    │       ├── grafana/
    │       ├── blackbox_exporter/
    │       └── event_service/
    ├── staging/                      # 15d retention · 15s scrape · 2 Kafka brokers
    │   ├── hosts.ini
    │   └── group_vars/
    │       ├── all/          # vault.yml + main.yml (env: staging)
    │       ├── prometheus/
    │       ├── alertmanager/
    │       ├── grafana/
    │       ├── blackbox_exporter/
    │       └── event_service/
    └── production/                   # 30d retention · 15s scrape · 3 Kafka brokers
        ├── hosts.ini
        └── group_vars/
            ├── all/          # vault.yml + main.yml (env: production)
            ├── prometheus/
            ├── alertmanager/
            ├── grafana/
            ├── blackbox_exporter/
            └── event_service/
```

---

## Prerequisites

- Ansible ≥ 2.13 (tested with 2.14+)
- Python 3 on the control node
- Target hosts: Rocky Linux 9 / RHEL / CentOS **or** Ubuntu 22.04 / Debian
- SSH access with `sudo` privileges on all target hosts
- Ansible collections installed via `requirements.yml`

---

## Quick Start

### 1. Clone

```bash
git clone https://github.com/abdukhoshimov/monitoring-automate.git
cd monitoring-automate
```

### 2. Install collections

```bash
ansible-galaxy collection install -r requirements.yml
```

### 3. Choose your environment and edit hosts

Replace placeholder hostnames with your actual servers:

```bash
# Choose one: dev | staging | production
ENV=production
vim inventories/$ENV/hosts.ini
```

### 4. Encrypt the vault

The vault files contain plaintext defaults — encrypt them before deploying:

```bash
ansible-vault encrypt inventories/$ENV/group_vars/all/vault.yml
# then set real credentials:
ansible-vault edit inventories/$ENV/group_vars/all/vault.yml
```

Vault keys:

```yaml
vault_grafana_admin_password: "your-strong-password"
vault_grafana_secret_key: "your-32-char-secret-key-minimum!"
```

### 5. Set blackbox targets

Edit `inventories/$ENV/group_vars/prometheus/main.yml`:

```yaml
prometheus_blackbox_http_targets:
  - "https://your-app.example.com"
  - "http://prometheus.example.com:9090/-/healthy"

prometheus_blackbox_tcp_targets:
  - "prometheus.example.com:9090"

prometheus_blackbox_icmp_targets:
  - "prometheus.example.com"
```

### 6. Set event service URL

Edit `inventories/$ENV/group_vars/alertmanager/main.yml`:

```yaml
alertmanager_event_service_url: "http://event-service.example.com:8080"
```

### 7. Deploy

Full stack:

```bash
# Dev
ansible-playbook -i inventories/dev site.yml --ask-vault-pass

# Staging
ansible-playbook -i inventories/staging site.yml --ask-vault-pass

# Production
ansible-playbook -i inventories/production site.yml --ask-vault-pass
```

Single component:

```bash
ansible-playbook -i inventories/production playbooks/prometheus.yml --ask-vault-pass
ansible-playbook -i inventories/production playbooks/grafana_api.yml --ask-vault-pass
```

---

## Deployment Order

`site.yml` deploys in this sequence, which resolves all dependencies:

```
common → node_exporter → blackbox_exporter → prometheus → alertmanager → grafana → grafana_api
```

- `grafana_api.yml` runs after `grafana` — the HTTP API must be up first
- `event_service.yml` runs last — Alertmanager must be up before the webhook target is live

---

## Upgrading a Component

1. Update the version variable in the relevant `group_vars` file (e.g. `prometheus_version`)
2. Update `prometheus_checksum.amd64` and `prometheus_checksum.arm64` (SHA256 of the new `.tar.gz`)
3. Re-run the component playbook — the role detects the version change and reinstalls

Checksum sources:

- Prometheus / Alertmanager / Node Exporter / Blackbox Exporter — [github.com/prometheus](https://github.com/prometheus)
- Grafana — [grafana.com/grafana/download](https://grafana.com/grafana/download?edition=oss)

---

## Running Tests

All roles are tested with Molecule (Docker driver) on Rocky Linux 9 and Ubuntu 22.04:

```bash
pip install -r molecule-requirements.txt
ansible-galaxy collection install -r requirements.yml

# Test a single role
cd roles/prometheus && molecule test

# Test all roles
for role in common node_exporter blackbox_exporter prometheus alertmanager grafana; do
  (cd roles/$role && molecule test)
done
```

CI runs automatically on every push via GitHub Actions (`.github/workflows/ci.yml`).

---

## Verification

```bash
# Health checks
curl http://prometheus-1.internal:9090/-/healthy
curl http://alertmanager-1.internal:9093/-/healthy

# Node Exporter metrics
curl http://<any-host>:9100/metrics | head -20

# Blackbox probe
curl "http://blackbox-1.internal:9115/probe?target=https://your-app.example.com&module=http_2xx"

# Grafana UI
open http://grafana-1.internal:3000   # admin / <vault_grafana_admin_password>
```

Alertmanager routing tree: `http://alertmanager-1.internal:9093/#/status`

---

## Security Notes

- All components run as dedicated non-root system users
- Firewall rules applied per-role — only the minimum required ports are opened
- Restrict Grafana (`:3000`) to VPN or an internal network — do not expose to the internet
- Set `vault_grafana_admin_password` before first deploy; never use defaults in production
- The `.vault_pass` file must be in `.gitignore` — never commit it
- For external access, place nginx with TLS in front of Grafana and Prometheus

---

## Roadmap

- [ ] Go event service implementation (webhook receiver → Kafka producer)
- [ ] TLS termination via nginx + Let's Encrypt
- [ ] Remote write to long-term storage (Mimir or VictoriaMetrics)
- [ ] Prometheus HA + Alertmanager clustering
- [ ] Multi-environment inventories (dev / staging / prod)

---

## Requirements Summary

| Requirement | Version |
|---|---|
| Ansible | ≥ 2.13 |
| `ansible.posix` | ≥ 1.5.0 |
| `community.general` | ≥ 8.0.0 |
| Target OS (RedHat) | Rocky Linux 9 / RHEL / CentOS |
| Target OS (Debian) | Ubuntu 22.04 / Debian |
| Architecture | amd64, arm64 |

---

## License

MIT
