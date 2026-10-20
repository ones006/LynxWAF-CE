#!/usr/bin/env bash
# ==============================================================================
# LynxWAF Community Edition — 1-Line Automated Quick Installer
#
# Standard Deployment Command:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/ones006/LynxWAF-CE/main/install.sh)"
#
# Supported Operating Systems:
#   Ubuntu 20.04/22.04/24.04, Debian 11/12, CentOS 7/8/9, Rocky Linux, AlmaLinux
#
# GitHub Repository: https://github.com/ones006/LynxWAF-CE
# Official Website : https://lynxwaf.id
# ==============================================================================

set -eo pipefail

# Visual Formatting
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

GITHUB_REPO="ones006/LynxWAF-CE"
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/main"

INSTALL_DIR="/opt/lynxwaf"
DEFAULT_PORT="8379"
WAF_PORT="${DEFAULT_PORT}"
NON_INTERACTIVE=false

# If running inside a git checkout or local folder with docker-compose.yml, use current directory
if [ -f "./docker-compose.yml" ]; then
    INSTALL_DIR="$(pwd)"
fi

print_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
  _                                     __          __     ______ 
 | |                                    \ \        / /\   |  ____|
 | |     _   _ _ __ __  ____      ____ _ \ \  /\  / /  \  | |__   
 | |    | | | | '_ \\ \/ /\ \ /\ / / _` | \ \/  \/ / /\ \ |  __|  
 | |____| |_| | | | |>  <  \ V  V / (_| |  \  /\  / ____ \| |     
 |______|\__, |_| |_/_/\_\  \_/\_/ \__,_|   \/  \/_/    \_\_|     
          __/ |                                                   
         |___/      COMMUNITY EDITION (FREE & UNENCUMBERED)       
EOF
    echo -e "${NC}"
    echo -e "${BOLD}Next-Gen Sovereign Web Application Firewall & Semantic L7 Defense${NC}"
    echo -e "Community Hub & Docs : ${BLUE}https://github.com/${GITHUB_REPO}${NC}"
    echo -e "Telegram Support     : ${BLUE}https://t.me/onelynxs${NC}"
    echo "------------------------------------------------------------------"
}

log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse Command-Line Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --port)
            WAF_PORT="$2"
            shift 2
            ;;
        -y|--non-interactive|--yes)
            NON_INTERACTIVE=true
            shift
            ;;
        -h|--help)
            echo "Usage: bash install.sh [options]"
            echo ""
            echo "Options:"
            echo "  --dir <path>       Target directory for installation (default: /opt/lynxwaf)"
            echo "  --port <port>      Cyber-SOC Web Console Port (default: 8379)"
            echo "  -y, --yes          Non-interactive mode (auto-accept defaults)"
            echo "  -h, --help         Show this help message"
            exit 0
            ;;
        *)
            log_warn "Unknown parameter: $1 (ignoring)"
            shift
            ;;
    esac
done

check_privileges() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "LynxWAF requires root privileges to bind ports 80/443 and orchestrate containers."
        echo "Please re-run using sudo: sudo bash $0 $*"
        exit 1
    fi
}

check_system_requirements() {
    log_info "Evaluating system prerequisites..."

    # Architecture validation
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            log_error "Unsupported hardware architecture: $ARCH. LynxWAF supports x86_64 and aarch64."
            exit 1
            ;;
    esac
    log_info "Architecture: ${GREEN}${ARCH}${NC}"

    # RAM Check
    if [ -f /proc/meminfo ]; then
        TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        TOTAL_RAM_MB=$(( TOTAL_RAM_KB / 1024 ))
        if [ "$TOTAL_RAM_MB" -lt 950 ]; then
            log_warn "System RAM is ${TOTAL_RAM_MB}MB. At least 1024MB RAM is recommended for optimal performance."
        else
            log_info "System Memory: ${GREEN}${TOTAL_RAM_MB}MB${NC} (OK)"
        fi
    fi

    # Port Availability Check
    for port in "$WAF_PORT" 80 443; do
        if command -v ss >/dev/null 2>&1; then
            if ss -tuln | grep -q ":${port} "; then
                log_warn "Port ${port} appears to be in use. Please ensure no conflicting web server (e.g. Apache/Nginx) is bound to it."
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -tuln | grep -q ":${port} "; then
                log_warn "Port ${port} appears to be in use. Please ensure no conflicting web server is bound to it."
            fi
        fi
    done
}

ensure_docker() {
    log_info "Checking container runtime (Docker & Docker Compose)..."

    if ! command -v docker >/dev/null 2>&1; then
        log_warn "Docker engine not found on this system."
        if [ "$NON_INTERACTIVE" = false ]; then
            read -r -p "Would you like to install official Docker now? (y/N): " install_docker_choice
            case "$install_docker_choice" in
                [yY][eE][sS]|[yY])
                    ;;
                *)
                    log_error "Docker is required to run LynxWAF. Aborting installation."
                    exit 1
                    ;;
            esac
        fi

        log_info "Installing Docker engine via official repository script..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker || true
    fi

    # Detect Docker Compose (v2 plugin or standalone)
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        log_warn "Docker Compose plugin not detected. Attempting automatic installation..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y -qq docker-compose-plugin || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y docker-compose-plugin || true
        fi

        if docker compose version >/dev/null 2>&1; then
            DOCKER_COMPOSE_CMD="docker compose"
        else
            log_error "Failed to install Docker Compose v2. Please install docker-compose manually and retry."
            exit 1
        fi
    fi

    log_success "Docker environment validated: $($DOCKER_COMPOSE_CMD version --short 2>/dev/null || echo 'ready')"
}

generate_random_secret() {
    local len="${1:-24}"
    local secret=""
    # Use head with finite buffer first to avoid SIGPIPE (exit code 141) under pipefail
    secret=$(head -c 512 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"$len" || true)
    if [ -z "$secret" ] || [ "${#secret}" -lt "$len" ]; then
        if command -v openssl >/dev/null 2>&1; then
            secret=$(openssl rand -base64 48 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"$len" || true)
        fi
    fi
    if [ -z "$secret" ] || [ "${#secret}" -lt "$len" ]; then
        secret="lynxwaf_sec_$(date +%s)"
    fi
    printf '%s' "$secret"
}

prepare_environment() {
    log_info "Preparing deployment directory at: ${INSTALL_DIR}"
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/config"
    mkdir -p "$INSTALL_DIR/data/mysql/data"
    mkdir -p "$INSTALL_DIR/data/mysql/log"
    mkdir -p "$INSTALL_DIR/data/nginx/logs"
    mkdir -p "$INSTALL_DIR/data/nginx/conf"
    mkdir -p "$INSTALL_DIR/data/nginx/conf.d"
    mkdir -p "$INSTALL_DIR/data/wwwroot"
    mkdir -p "$INSTALL_DIR/logs"

    cd "$INSTALL_DIR"

    # Fetch compose file if not present locally
    if [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
        log_info "Downloading official docker-compose.yml from GitHub..."
        curl -fsSL "${GITHUB_RAW}/docker-compose.yml" -o "$INSTALL_DIR/docker-compose.yml"
    fi

    # Fetch verification script if not present
    if [ ! -f "$INSTALL_DIR/test_poc_simulation.sh" ]; then
        log_info "Downloading attack simulation tool (test_poc_simulation.sh)..."
        curl -fsSL "${GITHUB_RAW}/test_poc_simulation.sh" -o "$INSTALL_DIR/test_poc_simulation.sh" 2>/dev/null || true
        chmod +x "$INSTALL_DIR/test_poc_simulation.sh" 2>/dev/null || true
    fi

    # Fetch updater script if not present
    if [ ! -f "$INSTALL_DIR/update.sh" ]; then
        curl -fsSL "${GITHUB_RAW}/update.sh" -o "$INSTALL_DIR/update.sh" 2>/dev/null || true
        chmod +x "$INSTALL_DIR/update.sh" 2>/dev/null || true
    fi

    # Generate secure .env if not present
    if [ ! -f "$INSTALL_DIR/.env" ]; then
        log_info "Generating cryptographic credentials for database & cache..."
        MYSQL_SECRET=$(generate_random_secret 24)
        REDIS_SECRET=$(generate_random_secret 24)
        ADMIN_PASS=$(generate_random_secret 12)
        AUTH_PATH=$(generate_random_secret 8)

        cat << EOF > "$INSTALL_DIR/.env"
# LynxWAF Community Edition Configuration
LYNXWAF_PORT=${WAF_PORT}
LYNXWAF_BIND_IP=0.0.0.0
LYNXWAF_ENV=production
LYNXWAF_DAEMON_IMAGE=ghcr.io/ones006/lynxwaf-daemon:ce-latest
LYNXWAF_OPENRESTY_IMAGE=ghcr.io/ones006/lynxwaf-openresty:ce-latest
MYSQL_ROOT_PASSWORD=${MYSQL_SECRET}
REDIS_PASSWORD=${REDIS_SECRET}
INITIAL_ADMIN_PASSWORD=${ADMIN_PASS}
SECURITY_ENTRANCE=${AUTH_PATH}
LYNXWAF_VERSION=ce-latest
EOF
        log_success "Configured credentials at: ${INSTALL_DIR}/.env"
    else
        log_info "Existing .env detected at ${INSTALL_DIR}/.env. Preserving current secrets."
    fi

    chmod 755 "$INSTALL_DIR"
    chmod 600 "$INSTALL_DIR/.env"

    # Grant read/write access to dedicated container non-root user (UID 1000: lynxwaf)
    chown -R 1000:1000 "$INSTALL_DIR/config" "$INSTALL_DIR/data" "$INSTALL_DIR/logs" 2>/dev/null || true
    chmod -R 775 "$INSTALL_DIR/config" "$INSTALL_DIR/data" "$INSTALL_DIR/logs" 2>/dev/null || true
}

start_stack() {
    log_info "Pulling official container images from GitHub Container Registry (GHCR)..."
    cd "$INSTALL_DIR"

    $DOCKER_COMPOSE_CMD pull || log_warn "Pull completed or using local cached images."

    # Initialize default configurations from container image if missing on host
    if [ ! -f "$INSTALL_DIR/config/sysconfig.json" ]; then
        log_info "Extracting default configurations from daemon container image..."
        docker run --rm -v "$INSTALL_DIR/config:/mnt_config" ghcr.io/ones006/lynxwaf-daemon:ce-latest sh -c 'cp -r /app/config/* /mnt_config/ 2>/dev/null || true' 2>/dev/null || true
        chown -R 1000:1000 "$INSTALL_DIR/config" 2>/dev/null || true
    fi

    log_info "Starting LynxWAF container services..."
    $DOCKER_COMPOSE_CMD up -d

    log_info "Waiting for LynxWAF Control Plane to complete initialization..."
    local attempts=0
    local max_attempts=30
    local healthy=false

    while [ $attempts -lt $max_attempts ]; do
        sleep 2
        attempts=$((attempts + 1))

        # 1. Primary check: inspect container status directly
        local daemon_status
        daemon_status=$(docker inspect -f '{{.State.Status}}' lynxwaf-daemon 2>/dev/null || true)
        if [ "$daemon_status" = "running" ]; then
            healthy=true
            break
        fi

        # 2. Fallback check: inspect via compose ps
        if $DOCKER_COMPOSE_CMD ps 2>/dev/null | grep -qiE "lynxwaf-daemon.*(up|running)"; then
            healthy=true
            break
        fi
        echo -n "."
    done
    echo ""

    if [ "$healthy" = true ]; then
        log_success "LynxWAF containers are running!"
    else
        log_warn "Containers started, awaiting initial health convergence. Run '$DOCKER_COMPOSE_CMD ps' to check."
    fi
}

initialize_admin_user() {
    cd "$INSTALL_DIR"
    local admin_pwd=""
    local desired_auth_path=""
    if [ -f ".env" ]; then
        admin_pwd=$(grep "^INITIAL_ADMIN_PASSWORD=" .env | cut -d '=' -f2- | tr -d '[:space:]')
        desired_auth_path=$(grep "^SECURITY_ENTRANCE=" .env | cut -d '=' -f2- | tr -d '[:space:]' | tr -d '/')
    fi

    if [ -n "$admin_pwd" ]; then
        log_info "Provisioning default administrative credentials..."
        docker exec lynxwaf-daemon /app/LynxWaf create_default_user admin "$admin_pwd" >/dev/null 2>&1 || true
    fi

    # Provision Security Entrance if not yet configured
    local current_auth_path
    current_auth_path=$(docker exec lynxwaf-daemon /app/LynxWaf get_auth_path 2>/dev/null | tr -d '[:space:]/' || true)

    if [ -z "$current_auth_path" ]; then
        [ -z "$desired_auth_path" ] && desired_auth_path=$(generate_random_secret 8)
        log_info "Configuring Security Entrance for Web Console..."
        docker exec lynxwaf-daemon /app/LynxWaf set_auth_path "$desired_auth_path" >/dev/null 2>&1 || true
    elif [ -n "$desired_auth_path" ] && [ "$current_auth_path" != "$desired_auth_path" ]; then
        docker exec lynxwaf-daemon /app/LynxWaf set_auth_path "$desired_auth_path" >/dev/null 2>&1 || true
    fi
}

display_completion_banner() {
    local host_ip
    host_ip=$(curl -s --connect-timeout 3 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    
    local admin_pwd
    if [ -f "$INSTALL_DIR/.env" ]; then
        admin_pwd=$(grep "^INITIAL_ADMIN_PASSWORD=" "$INSTALL_DIR/.env" | cut -d '=' -f2- | tr -d '[:space:]')
    fi
    [ -z "$admin_pwd" ] && admin_pwd="(previously configured)"

    local auth_path
    auth_path=$(docker exec lynxwaf-daemon /app/LynxWaf get_auth_path 2>/dev/null | tr -d '[:space:]' || true)
    if [ -z "$auth_path" ] && [ -f "$INSTALL_DIR/.env" ]; then
        local env_path
        env_path=$(grep "^SECURITY_ENTRANCE=" "$INSTALL_DIR/.env" | cut -d '=' -f2- | tr -d '[:space:]' | tr -d '/')
        [ -n "$env_path" ] && auth_path="/${env_path}"
    fi
    [ -n "$auth_path" ] && [ "${auth_path:0:1}" != "/" ] && auth_path="/${auth_path}"

    echo ""
    echo -e "${GREEN}${BOLD}========================================================================${NC}"
    echo -e "${GREEN}${BOLD}       LynxWAF Community Edition Deployment Completed Successfully!     ${NC}"
    echo -e "${GREEN}${BOLD}========================================================================${NC}"
    echo ""
    echo -e "  ${BOLD}Web Console URL${NC}   : ${CYAN}https://${host_ip}:${WAF_PORT}${auth_path}${NC}"
    if [ -n "$auth_path" ]; then
    echo -e "  ${BOLD}Security Entrance${NC} : ${YELLOW}${auth_path}${NC}"
    fi
    echo -e "  ${BOLD}Default Username${NC}  : ${BOLD}admin${NC}"
    echo -e "  ${BOLD}Initial Password${NC}  : ${YELLOW}${admin_pwd}${NC}"
    echo -e "  ${BOLD}Deployment Path${NC}   : ${INSTALL_DIR}"
    echo -e "  ${BOLD}License Mode${NC}      : ${GREEN}Community Edition (Free Forever · Up to 3 Domains · 1 Node)${NC}"
    echo ""
    echo -e "  ${BOLD}Useful Management Commands:${NC}"
    echo -e "    • View Service Status : ${CYAN}cd ${INSTALL_DIR} && ${DOCKER_COMPOSE_CMD} ps${NC}"
    echo -e "    • Live Attack Logs    : ${CYAN}cd ${INSTALL_DIR} && ${DOCKER_COMPOSE_CMD} logs -f lynxwaf-openresty${NC}"
    echo -e "    • Restart Defense     : ${CYAN}cd ${INSTALL_DIR} && ${DOCKER_COMPOSE_CMD} restart${NC}"
    echo -e "    • Test WAF Protection : ${CYAN}cd ${INSTALL_DIR} && ./test_poc_simulation.sh https://${host_ip}${NC}"
    echo -e "    • Reset Password      : ${CYAN}docker exec -it lynxwaf-daemon /app/LynxWaf reset_password <new_pwd>${NC}"
    echo -e "    • View Entrance Path  : ${CYAN}docker exec -it lynxwaf-daemon /app/LynxWaf get_auth_path${NC}"
    echo -e "    • Reset Entrance Path : ${CYAN}docker exec -it lynxwaf-daemon /app/LynxWaf set_auth_path <new_path>${NC}"
    echo -e "    • Disable Entrance    : ${CYAN}docker exec -it lynxwaf-daemon /app/LynxWaf disable_auth_path${NC}"
    echo ""
    echo -e "  ${BOLD}Note on HTTPS Certificate:${NC}"
    echo -e "    LynxWAF initializes with a self-signed TLS certificate."
    echo -e "    You may safely accept the browser warning on initial login,"
    echo -e "    or bind your trusted domain certificate via the Web Console."
    echo ""
    echo -e "  ${BOLD}Need Enterprise Multi-Node / Compliance Outbound DLP?${NC}"
    echo -e "    Contact via Telegram: ${BLUE}https://t.me/onelynxs${NC} (or email: ones006@gmail.com)"
    echo -e "${GREEN}${BOLD}========================================================================${NC}"
    echo ""
}

send_install_telemetry() {
    local host_arch="${ARCH:-$(uname -m)}"
    # Send anonymous install ping to Telegram relay (resilient to ISP DNS blocks via DoH)
    curl -s --connect-timeout 4 --max-time 6 --doh-url https://1.1.1.1/dns-query \
        "https://lynxwaf-counter.ones006.workers.dev/installed?arch=${host_arch}" >/dev/null 2>&1 \
        || curl -s --connect-timeout 4 --max-time 6 \
        "https://lynxwaf-counter.ones006.workers.dev/installed?arch=${host_arch}" >/dev/null 2>&1 \
        || true
}

main() {
    print_banner
    check_privileges
    check_system_requirements
    ensure_docker
    prepare_environment
    start_stack
    initialize_admin_user
    display_completion_banner
    send_install_telemetry
}

main "$@"
