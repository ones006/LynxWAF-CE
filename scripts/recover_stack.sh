#!/usr/bin/env bash
# ==============================================================================
# LynxWAF - Automated Recovery & Stack Initialization Script
#
# This script performs a complete, permanent, and automated recovery:
#   1. Resolves installation directory (/opt/lynxwaf by default)
#   2. Cleans up hanging eBPF overlays & stopped containers
#   3. Ensures docker-compose.yml has persistent volume mounts (including ./ssl)
#   4. Deploys the PT Tangara Mitrakom Enterprise Perpetual License
#   5. Applies hardened permissions (UID 1000: lynxwaf)
#   6. Pulls latest production images (v26.11.03.1 / ce-latest) and restarts stack
#   7. Performs automated health verification on port 8379
# ==============================================================================

set -eo pipefail

BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()         { log_error "$*"; exit 1; }

# 1. Root Check
if [ "$(id -u)" != "0" ]; then
    die "This script must be run as root. Please run with sudo: sudo bash $0"
fi

# 2. Resolve Target Directory
INSTALL_DIR="/opt/lynxwaf"
if [ -f "./docker-compose.yml" ]; then
    INSTALL_DIR="$(pwd)"
elif [ ! -d "$INSTALL_DIR" ]; then
    die "Could not find LynxWAF deployment directory. (Checked ./ and /opt/lynxwaf)"
fi

cd "$INSTALL_DIR"
log_info "Target installation directory: ${BOLD}${INSTALL_DIR}${NC}"

# Detect Docker Compose command
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
else
    die "Docker Compose not found. Please ensure Docker Compose is installed."
fi

echo -e "\n${BOLD}=====================================================================${NC}"
echo -e "${BOLD}      LynxWAF Stack Recovery & Permanent Normalization Tool          ${NC}"
echo -e "${BOLD}=====================================================================${NC}\n"

# 3. Clean up experimental / blocking eBPF overlay
if [ -f "docker-compose.ebpf.yml" ]; then
    log_info "Backing up and disabling experimental docker-compose.ebpf.yml..."
    mv docker-compose.ebpf.yml "docker-compose.ebpf.yml.bak.$(date +%Y%m%d%H%M%S)"
    log_success "eBPF overlay disabled to restore clean, unencumbered L7 WAF operation."
fi
unset COMPOSE_FILE 2>/dev/null || true

# 4. Stop stuck or lingering containers
log_info "Stopping any stuck containers..."
"${COMPOSE_CMD[@]}" down --remove-orphans 2>/dev/null || true

# Remove any lingering run-temp containers and stale file locks
for c in $(docker ps -a --filter "name=lynxwaf-lynxwaf-daemon-run" -q 2>/dev/null || true); do
    docker rm -f "$c" >/dev/null 2>&1 || true
done
rm -f data/.lock data/.pid 2>/dev/null || true
log_success "Stale containers and process lockfiles cleaned."

# 5. Ensure docker-compose.yml has ./ssl mount
if [ -f "docker-compose.yml" ]; then
    if ! grep -q '\./ssl:/app/ssl' docker-compose.yml; then
        log_info "Adding missing ./ssl:/app/ssl:rw mount to docker-compose.yml..."
        sed -i.bak '/\.\/data:\/app\/data:rw/a \      - ./ssl:/app/ssl:rw' docker-compose.yml
        log_success "Added ./ssl:/app/ssl:rw to lynxwaf-daemon volumes."
    fi
fi

# 6. Deploy PT Tangara Mitrakom Enterprise Perpetual License
mkdir -p config
log_info "Installing Enterprise Perpetual License for PT Tangara Mitrakom..."
cat << 'EOF' > config/lynxwaf.lic
{
  "data": {
    "license_id": "LYNX-ENTE-2026-6C84812C",
    "customer": "PT Tangara Mitrakom",
    "tier": "enterprise_ha_pair",
    "type": "perpetual",
    "issued_at": "2026-11-03T02:17:47Z",
    "valid_until": "forever",
    "key_id": "lynxwaf-2026",
    "max_nodes": 0,
    "max_domains": 0,
    "features": {
      "ai_guardrails": true,
      "bot_intelligence": true,
      "compliance_pdf": true,
      "ebpf_xdp": true,
      "geo_mesh": true,
      "keepalived_vrrp": true,
      "managed_soc": true,
      "multi_tenant": true,
      "outbound_dlp": true,
      "whitelabel": true
    }
  },
  "signature": "lGCbm70XwLVKazwHKhLbjXZiI7pPST4F+yhRAbtOsbwR9fOIvoGIoup58+tTFnHYZ+eaEmO1urWugC8K1sckDg=="
}
EOF
log_success "Enterprise Perpetual License installed in config/lynxwaf.lic"

# 7. Apply proper directory structure and ownership
log_info "Enforcing correct directory permissions (UID 1000)..."
mkdir -p ssl config data logs
chown -R 1000:1000 ssl config data logs
chmod -R 775 ssl config data logs
log_success "Directory permissions normalized."

# 8. Pull latest images and restart stack
log_info "Pulling latest container images (v26.11.03.1 / ce-latest)..."
"${COMPOSE_CMD[@]}" pull

log_info "Starting LynxWAF container stack..."
"${COMPOSE_CMD[@]}" up -d --force-recreate

# 9. Health Verification
log_info "Waiting for services to become healthy..."
MAX_WAIT=25
READY=false

for i in $(seq 1 "$MAX_WAIT"); do
    sleep 1
    if nc -z 127.0.0.1 8379 2>/dev/null || curl -k -s -o /dev/null --connect-timeout 2 https://127.0.0.1:8379 2>/dev/null; then
        READY=true
        break
    fi
    printf "."
done
echo ""

if [ "$READY" = true ]; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '127.0.0.1')"
    echo -e "\n${GREEN}${BOLD}✔ LynxWAF Stack Successfully Recovered & Running!${NC}"
    echo -e "---------------------------------------------------------------------"
    echo -e "  • Web Console HTTPS : ${CYAN}https://${SERVER_IP}:8379${NC}"
    echo -e "  • License Customer  : ${BOLD}PT Tangara Mitrakom${NC}"
    echo -e "  • License Edition   : ${BOLD}Enterprise HA Pair (Perpetual / Forever)${NC}"
    echo -e "  • Domains / Nodes   : ${BOLD}Unlimited${NC}"
    echo -e "  • Active Ports      : 80, 443, 8379"
    echo -e "---------------------------------------------------------------------\n"
    "${COMPOSE_CMD[@]}" ps
else
    log_warn "Web console did not respond within ${MAX_WAIT}s. Inspecting container logs:"
    docker logs --tail 30 lynxwaf-daemon 2>&1 || true
    echo -e "\nCheck container status with: sudo docker ps"
fi

