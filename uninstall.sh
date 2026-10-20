#!/usr/bin/env bash
# ==============================================================================
# LynxWAF Community Edition — Clean & Total Uninstaller
# Repository: https://github.com/ones006/LynxWAF-CE
#
# Usage:
#   cd /opt/lynxwaf && sudo ./uninstall.sh [--force] [--purge-images]
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

FORCE=false
PURGE_IMAGES=false
INSTALL_DIR="/opt/lynxwaf"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            FORCE=true
            shift
            ;;
        --purge-images)
            PURGE_IMAGES=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[ERROR] LynxWAF uninstaller requires root privileges. Please run with sudo.${NC}"
    exit 1
fi

echo -e "\n${RED}${BOLD}========================================================================${NC}"
echo -e "${RED}${BOLD}             LynxWAF Community Edition — Total Uninstaller              ${NC}"
echo -e "${RED}${BOLD}========================================================================${NC}"
echo -e "${YELLOW}WARNING: This action will completely stop all LynxWAF services and delete:${NC}"
echo -e "  • All LynxWAF containers (daemon, openresty proxy, mysql, redis)"
echo -e "  • All attack logs, telemetry, and threat history"
echo -e "  • All database configurations, SSL certificates, and user accounts"
echo -e "  • The deployment directory at: ${BOLD}${INSTALL_DIR}${NC}\n"

if [ "$FORCE" = false ]; then
    read -r -p "Are you absolutely sure you want to proceed? (type 'yes' to confirm): " confirm
    if [ "$confirm" != "yes" ]; then
        echo -e "\n${CYAN}Uninstallation cancelled.${NC}\n"
        exit 0
    fi
fi

# Detect Docker Compose
DOCKER_COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker-compose"
fi

echo -e "\n${CYAN}[1/4] Stopping and removing LynxWAF containers & networks...${NC}"
if [ -d "$INSTALL_DIR" ] && [ -n "$DOCKER_COMPOSE_CMD" ]; then
    (cd "$INSTALL_DIR" && $DOCKER_COMPOSE_CMD down -v --remove-orphans 2>/dev/null) || true
fi

# Force cleanup any lingering containers by name
for container in lynxwaf-daemon lynxwaf-openresty lynxwaf-mysql lynxwaf-redis; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        echo -e "Removing lingering container: ${container}..."
        docker rm -f "$container" >/dev/null 2>&1 || true
    fi
done

if [ "$PURGE_IMAGES" = true ]; then
    echo -e "\n${CYAN}[2/4] Removing container images from local cache...${NC}"
    docker rmi ghcr.io/ones006/lynxwaf-daemon:ce-latest \
               ghcr.io/ones006/lynxwaf-openresty:ce-latest \
               mysql:8.0 \
               redis:7-alpine >/dev/null 2>&1 || true
else
    echo -e "\n${CYAN}[2/4] Skipping image purge (pass '--purge-images' to delete cached images).${NC}"
fi

echo -e "\n${CYAN}[3/4] Deleting installation directory (${INSTALL_DIR})...${NC}"
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
fi

echo -e "\n${CYAN}[4/4] Verifying port reclamation...${NC}"
for port in 80 443 8379; do
    if command -v ss >/dev/null 2>&1; then
        if ! ss -tuln | grep -q ":${port} "; then
            echo -e "  • Port ${port}: ${GREEN}CLEARED (Free)${NC}"
        fi
    fi
done

echo -e "\n${GREEN}${BOLD}✔ LynxWAF Community Edition has been completely uninstalled from this server.${NC}\n"
