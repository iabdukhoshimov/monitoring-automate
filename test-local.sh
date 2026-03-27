#!/usr/bin/env bash
# test-local.sh — Deploy the full monitoring stack onto a local Docker container
# and verify all services are reachable.
#
# Usage:
#   ./test-local.sh          # full deploy
#   ./test-local.sh --down   # stop and remove the test container

set -euo pipefail

INVENTORY="inventories/docker/hosts.ini"
CONTAINER="mon-node"
COMPOSE_FILE="docker/docker-compose.ansible-test.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── Teardown ──────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--down" ]]; then
  log "Stopping test container..."
  docker compose -f "$COMPOSE_FILE" down
  log "Done."
  exit 0
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
command -v docker      >/dev/null 2>&1 || fail "docker not found"
command -v ansible-playbook >/dev/null 2>&1 || fail "ansible-playbook not found"

# ── Install collections ───────────────────────────────────────────────────────
log "Installing Ansible collections..."
ansible-galaxy collection install -r requirements.yml

# Install docker Python lib (needed by community.docker connection plugin)
pip install docker --quiet 2>/dev/null || warn "Could not install docker Python lib — may already be installed"

# ── Start container ───────────────────────────────────────────────────────────
log "Starting test container (Rocky Linux 9 + systemd)..."
docker compose -f "$COMPOSE_FILE" up -d

log "Waiting for systemd to be ready..."
RETRIES=20
until docker exec "$CONTAINER" systemctl is-system-running --quiet 2>/dev/null; do
  RETRIES=$((RETRIES - 1))
  [[ $RETRIES -eq 0 ]] && fail "Container systemd did not start in time"
  sleep 2
done
log "Systemd is ready."

# ── Run Ansible ───────────────────────────────────────────────────────────────
log "Running ansible-playbook site.yml..."
ansible-playbook -i "$INVENTORY" site.yml \
  --diff \
  -e "ansible_python_interpreter=auto_silent"

# ── Verify services ───────────────────────────────────────────────────────────
log "Verifying services..."
sleep 3

check() {
  local name="$1" url="$2"
  if curl -sf --max-time 5 "$url" >/dev/null; then
    echo -e "  ${GREEN}✓${NC} $name — $url"
  else
    echo -e "  ${RED}✗${NC} $name — $url"
  fi
}

check "Prometheus"        "http://localhost:9090/-/healthy"
check "Alertmanager"      "http://localhost:9093/-/healthy"
check "Grafana"           "http://localhost:3000/api/health"
check "Node Exporter"     "http://localhost:9100/metrics"
check "Blackbox Exporter" "http://localhost:9115/metrics"

echo ""
log "Done! Open these in your browser:"
echo "  Grafana      → http://localhost:3000  (admin / admin)"
echo "  Prometheus   → http://localhost:9090"
echo "  Alertmanager → http://localhost:9093"
echo ""
echo "  To stop: ./test-local.sh --down"
