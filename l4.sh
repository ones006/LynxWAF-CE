#!/usr/bin/env bash
# ==============================================================================
# LynxWAF L4 Datapath Switch (Kernel-Level eBPF / XDP) - one-time host setup
#
#   sudo bash l4.sh enable    # grant the daemon kernel access (once), then use the console toggle
#   sudo bash l4.sh disable   # back to the fully hardened default stack
#   sudo bash l4.sh refresh   # regenerate the overlay from the current image (update.sh does this)
#   sudo bash l4.sh status
#
# Why a host step exists at all: a container cannot grant itself CAP_BPF /
# CAP_NET_ADMIN or join the host network namespace. This script does it once;
# after that every on/off is a click on the console toggle (Network Defense L4).
#
# The overlay text is printed by the daemon image itself ("ebpf --overlay"), so
# it always matches the binary that runs it. It is activated through
# COMPOSE_FILE in .env, so plain "docker compose" and update.sh keep using it.
# ==============================================================================
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY="docker-compose.ebpf.yml"
COMPOSE_VALUE="docker-compose.yml:${OVERLAY}"

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "[INFO] $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash l4.sh ${1:-status}"
[ -f docker-compose.yml ] && [ -f .env ] || die "Run from the LynxWAF install directory (default /opt/lynxwaf)."

if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE=(docker-compose)
else die "Docker Compose not found."; fi

l4_enabled() { grep -q "^COMPOSE_FILE=.*${OVERLAY}" .env 2>/dev/null; }

set_env_compose_file() {
    sed -i.bak '/^COMPOSE_FILE=/d' .env
    [ -n "$1" ] && echo "COMPOSE_FILE=$1" >> .env
    chmod 600 .env
}

preflight_kernel() {
    [ "$(uname -s)" = "Linux" ] || die "XDP needs a Linux host."
    local major minor
    IFS=. read -r major minor _ <<< "$(uname -r)"
    if [ "$major" -lt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -lt 8 ]; }; then
        die "Kernel $(uname -r) is too old for CAP_BPF; 5.8+ is required (5.15+ recommended)."
    fi
    [ -f /sys/kernel/btf/vmlinux ] || warn "/sys/kernel/btf/vmlinux missing: this kernel may lack BTF; attach can still fail."
}

generate_overlay() {
    local tmp="${OVERLAY}.new"
    # Generate with the base file only, so a stale overlay cannot break generation.
    if ! COMPOSE_FILE=docker-compose.yml "${COMPOSE[@]}" run --rm --no-deps -T lynxwaf-daemon ebpf --overlay > "$tmp" 2>/dev/null \
        || ! grep -q 'entrypoint: /app/LynxWaf-l4' "$tmp"; then
        rm -f "$tmp"
        die "The daemon image does not ship the L4 overlay yet. Run 'sudo bash update.sh' first."
    fi
    [ -f "$OVERLAY" ] && ! cmp -s "$tmp" "$OVERLAY" && cp -p "$OVERLAY" "${OVERLAY}.bak.$(date +%Y%m%d%H%M%S)"
    mv "$tmp" "$OVERLAY"
    chmod 600 "$OVERLAY"
}

wait_healthy() {
    local i
    for i in $(seq 1 30); do
        sleep 2
        if docker inspect -f '{{.State.Running}}' lynxwaf-daemon 2>/dev/null | grep -q true \
           && [ "$(docker inspect -f '{{.RestartCount}}' lynxwaf-daemon 2>/dev/null || echo 9)" -lt 3 ] \
           && (exec 3<>/dev/tcp/127.0.0.1/8379) 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

recreate_daemon() {
    mkdir -p ssl && chown 1000:1000 ssl 2>/dev/null || true
    "${COMPOSE[@]}" up -d --force-recreate lynxwaf-daemon
}

cmd_enable() {
    preflight_kernel
    if [ "${ASSUME_YES:-false}" != true ] && [ -t 0 ]; then
        echo -e "${BOLD}Enabling the L4 datapath changes how the console container runs:${NC}"
        echo "  * it joins the host network: the console listens on port 8379 on ALL interfaces"
        echo "    (LYNXWAF_BIND_IP no longer restricts it) - firewall it if the host is public;"
        echo "  * it gains CAP_BPF, CAP_NET_ADMIN and CAP_SYS_ADMIN (still uid 1000)."
        read -r -p "Continue? [y/N] " a
        [[ "$a" =~ ^[Yy]$ ]] || { info "Nothing changed."; exit 0; }
    fi
    generate_overlay
    set_env_compose_file "$COMPOSE_VALUE"
    recreate_daemon
    if ! wait_healthy; then
        warn "The daemon did not come up with the overlay - rolling back to the default stack."
        cmd_disable_quiet
        die "L4 enable rolled back. See: docker logs lynxwaf-daemon"
    fi
    ok "Kernel access granted. Open the console > Network Defense (L4) and switch the toggle ON."
}

cmd_disable_quiet() {
    set_env_compose_file ""
    COMPOSE_FILE=docker-compose.yml "${COMPOSE[@]}" up -d --force-recreate lynxwaf-daemon
}

cmd_disable() {
    cmd_disable_quiet
    ok "Back on the default hardened stack. ${OVERLAY} is kept but unused."
}

cmd_refresh() {
    l4_enabled || { info "L4 overlay is not enabled; nothing to refresh."; return 0; }
    generate_overlay
    ok "${OVERLAY} regenerated from the current image."
}

cmd_status() {
    if l4_enabled; then ok "L4 host access: ENABLED (COMPOSE_FILE uses ${OVERLAY})"
    else info "L4 host access: disabled (default hardened stack)"; fi
    docker exec lynxwaf-daemon /app/LynxWaf-l4 ebpf --status 2>/dev/null | sed -n '1,8p' || true
}

case "${1:-status}" in
    enable)  ASSUME_YES="${ASSUME_YES:-false}"; [ "${2:-}" = "-y" ] && ASSUME_YES=true; cmd_enable ;;
    disable) cmd_disable ;;
    refresh) cmd_refresh ;;
    status)  cmd_status ;;
    *) die "Usage: sudo bash l4.sh {enable|disable|refresh|status}" ;;
esac

