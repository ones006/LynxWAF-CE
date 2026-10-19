#!/usr/bin/env bash
# ==============================================================================
# LynxWAF Community Edition — One-Command In-Place Updater
# Repository: https://github.com/ones006/LynxWAF-CE
# ==============================================================================

set -eo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$SCRIPT_DIR"

echo -e "${CYAN}${BOLD}======================================================================${NC}"
echo -e "${CYAN}${BOLD}            LynxWAF Community Edition — In-Place Updater             ${NC}"
echo -e "${CYAN}${BOLD}======================================================================${NC}"

# Detect Docker Compose
if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker-compose"
else
    echo -e "${RED}[ERROR] Docker Compose command not found.${NC}"
    exit 1
fi

echo -e "\n[1/3] Pulling updated container images from GHCR..."
$DOCKER_COMPOSE_CMD pull

echo -e "\n[2/3] Recreating containers with latest image versions..."
$DOCKER_COMPOSE_CMD up -d --remove-orphans

echo -e "\n[3/3] Validating running services..."
sleep 3
$DOCKER_COMPOSE_CMD ps

echo -e "\n${GREEN}${BOLD}✔ LynxWAF Community Edition updated successfully!${NC}\n"
