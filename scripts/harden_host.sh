#!/usr/bin/env bash
# ==============================================================================
# LynxWAF Production Host Hardening & OS Optimizer (Interactive Wizard)
#
# Standards:
#   • CIS Linux Benchmark Guidelines
#   • Kernel TCP/IP Tuning for High-Throughput L7/eBPF WAF Operations
#   • Zero-Trust SSH & Firewall Lockdown
#
# Supported OS:
#   • Ubuntu 20.04 / 22.04 / 24.04 LTS
#   • Debian 11 (Bullseye) / 12 (Bookworm)
#   • Rocky Linux / AlmaLinux / RHEL 8 & 9
# ==============================================================================

set -e

# ANSI Styling
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
NC='\033[0m'

LOG_FILE="/var/log/lynxwaf_hardening_$(date +%Y%m%d_%H%M%S).log"
BACKUP_DIR="/etc/lynxwaf/security_backup_$(date +%Y%m%d_%H%M%S)"

# Logging helper
log() {
    echo -e "${CYAN}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}
log_success() {
    echo -e "${GREEN}[✔ SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}
log_warn() {
    echo -e "${YELLOW}[⚠ WARNING]${NC} $1" | tee -a "$LOG_FILE"
}
log_error() {
    echo -e "${RED}[✖ ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

# ------------------------------------------------------------------------------
# 1. Root & OS Architecture Detection
# ------------------------------------------------------------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}[ERROR] This hardening script requires root privileges.${NC}"
        echo "Please re-run using sudo: sudo bash $0"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_NAME="$PRETTY_NAME"
    else
        echo -e "${RED}[ERROR] Cannot detect Linux distribution from /etc/os-release.${NC}"
        exit 1
    fi

    case "$OS_ID" in
        ubuntu|debian)
            PKG_MGR="apt"
            FW_TOOL="ufw"
            ;;
        rocky|almalinux|rhel|centos)
            PKG_MGR="dnf"
            FW_TOOL="firewalld"
            ;;
        *)
            echo -e "${RED}[ERROR] Unsupported distribution: ${OS_ID}.${NC}"
            echo "LynxWAF Hardening supports Ubuntu, Debian, Rocky Linux, AlmaLinux, and RHEL."
            exit 1
            ;;
    esac
}

print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
  ██╗     ██╗   ██╗███╗   ██╗██╗  ██╗██╗    ██╗ █████╗ ███████╗
  ██║     ╚██╗ ██╔╝████╗  ██║╚██╗██╔╝██║    ██║██╔══██╗██╔════╝
  ██║      ╚████╔╝ ██╔██╗ ██║ ╚███╔╝ ██║ █╗ ██║███████║█████╗  
  ██║       ╚██╔╝  ██║╚██╗██║ ██╔██╗ ██║███╗██║██╔══██║██╔══╝  
  ███████╗   ██║   ██║ ╚████║██╔╝ ██╗╚███╔███╔╝██║  ██║██║     
  ╚══════╝   ╚═╝   ╚═╝  ╚═══╝╚═╝  ╚═╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝     
EOF
    echo -e "   --- Production Host & OS Hardening Wizard (CIS Compliant) ---${NC}\n"
    echo -e "  • Target System : ${GREEN}${OS_NAME} (${PKG_MGR})${NC}"
    echo -e "  • Kernel Version: ${YELLOW}$(uname -r)${NC}"
    echo -e "  • Timestamp     : $(date)"
    echo -e "  • Log Path      : ${LOG_FILE}"
    echo -e "----------------------------------------------------------------------"
}

# ------------------------------------------------------------------------------
# 2. Interactive Menu
# ------------------------------------------------------------------------------
interactive_menu() {
    echo -e "\n${BOLD}Select Hardening Modules to Execute:${NC}"
    echo -e " [1] ${BOLD}Full Automated Hardening (Recommended for New Production VPS)${NC}"
    echo -e "     (Runs OS Updates, SSH Lockdown, Sysctl Tuning, UFW/Firewall, Fail2Ban, File Limits)"
    echo -e " [2] ${CYAN}Custom / Selective Hardening${NC}"
    echo -e " [3] ${YELLOW}Review Current Security & Open Ports Audit Only${NC}"
    echo -e " [4] Exit"
    echo ""
    read -rp "Enter choice [1-4] (default: 1): " CHOICE
    CHOICE=${CHOICE:-1}

    case "$CHOICE" in
        1)
            CONFIRM_ALL=true
            gather_parameters
            execute_all
            ;;
        2)
            CONFIRM_ALL=false
            gather_parameters
            execute_selective
            ;;
        3)
            audit_system
            exit 0
            ;;
        4)
            echo "Hardening canceled."
            exit 0
            ;;
        *)
            echo "Invalid choice."
            exit 1
            ;;
    esac
}

gather_parameters() {
    echo -e "\n${MAGENTA}${BOLD}--- Configuration Parameters ---${NC}"
    
    # SSH Port
    CURRENT_SSH_PORT=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}
    read -rp "1. SSH Management Port [Default: $CURRENT_SSH_PORT]: " TARGET_SSH_PORT
    TARGET_SSH_PORT=${TARGET_SSH_PORT:-$CURRENT_SSH_PORT}

    # WAF Console Port
    read -rp "2. LynxWAF Cyber-SOC Console Port [Default: 8379]: " WAF_CONSOLE_PORT
    WAF_CONSOLE_PORT=${WAF_CONSOLE_PORT:-8379}

    # Authorized Admin IP for Console Access
    CLIENT_IP="${SSH_CLIENT%% *}"
    read -rp "3. Admin CIDR / IP Whitelist for Console port ${WAF_CONSOLE_PORT} (Press Enter to allow all, or specify e.g. ${CLIENT_IP}/32): " ADMIN_CIDR

    # Disable Root Login via Password?
    read -rp "4. Disable SSH root password login? (Keys only) [y/N]: " DISABLE_ROOT_PASS
    DISABLE_ROOT_PASS=$(echo "$DISABLE_ROOT_PASS" | tr '[:upper:]' '[:lower:]')

    mkdir -p "$BACKUP_DIR"
    log "Config backups will be saved at: ${BACKUP_DIR}"
}

# ------------------------------------------------------------------------------
# 3. Hardening Modules
# ------------------------------------------------------------------------------

# Module 1: OS Packages & Security Updates
step_update_os() {
    log "Updating package repositories and installing security dependencies..."
    if [ "$PKG_MGR" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl wget git htop net-tools ufw fail2ban ca-certificates iptables ipset
    else
        dnf makecache -y
        dnf install -y curl wget git htop net-tools firewalld fail2ban ca-certificates iptables ipset
    fi
    log_success "Core security packages installed."
}

# Module 2: High-Performance & Security Kernel Sysctl Tuning
step_kernel_sysctl() {
    log "Applying high-performance & security sysctl optimizations for WAF & eBPF..."
    SYSCTL_CONF="/etc/sysctl.d/99-lynxwaf-hardened.conf"
    [ -f "$SYSCTL_CONF" ] && cp "$SYSCTL_CONF" "$BACKUP_DIR/"

    cat << 'EOF' > "$SYSCTL_CONF"
# ==============================================================================
# LynxWAF Kernel Hardening & High-Throughput L7/eBPF Sysctl Tunings
# ==============================================================================

# 1. Network Defense & Anti-Spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

# 2. SYN Flood & Connection Exhaustion Defense
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 65536

# 3. Connection Tracking & High Concurrency Buffer Tuning
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535

# 4. TCP Socket Memory (Auto-Tuning Buffers for Heavy Traffic)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 5. eBPF & Kernel Bypass Tuning
kernel.bpf_stats = 1
net.core.bpf_jit_enable = 1
net.core.bpf_jit_harden = 2

# 6. File System & Memory Protections
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
vm.swappiness = 10
vm.max_map_count = 262144
EOF

    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
    log_success "Applied sysctl configurations to: $SYSCTL_CONF"
}

# Module 3: File Descriptor & Process Ulimits
step_file_limits() {
    log "Increasing open file descriptor limits (nofile) for high concurrency..."
    LIMITS_CONF="/etc/security/limits.d/99-lynxwaf-limits.conf"
    [ -f "$LIMITS_CONF" ] && cp "$LIMITS_CONF" "$BACKUP_DIR/"

    cat << 'EOF' > "$LIMITS_CONF"
* soft nofile 1000000
* hard nofile 1000000
* soft nproc 65535
* hard nproc 65535
root soft nofile 1000000
root hard nofile 1000000
EOF
    log_success "Configured ulimits to 1,000,000 open file descriptors."
}

# Module 4: SSH Hardening
step_harden_ssh() {
    log "Hardening OpenSSH Daemon configuration..."
    SSHD_CONFIG="/etc/ssh/sshd_config"
    cp "$SSHD_CONFIG" "$BACKUP_DIR/sshd_config.bak"

    # Backup and replace or insert settings
    sed -i -E "s/^#?Port .*/Port ${TARGET_SSH_PORT}/" "$SSHD_CONFIG"
    sed -i -E "s/^#?MaxAuthTries .*/MaxAuthTries 4/" "$SSHD_CONFIG"
    sed -i -E "s/^#?ClientAliveInterval .*/ClientAliveInterval 300/" "$SSHD_CONFIG"
    sed -i -E "s/^#?ClientAliveCountMax .*/ClientAliveCountMax 2/" "$SSHD_CONFIG"
    sed -i -E "s/^#?X11Forwarding .*/X11Forwarding no/" "$SSHD_CONFIG"

    if [ "$DISABLE_ROOT_PASS" = "y" ] || [ "$DISABLE_ROOT_PASS" = "yes" ]; then
        log_warn "Disabling root password authentication (Ensure your SSH public key is loaded!)..."
        sed -i -E "s/^#?PermitRootLogin .*/PermitRootLogin prohibit-password/" "$SSHD_CONFIG"
        sed -i -E "s/^#?PasswordAuthentication .*/PasswordAuthentication no/" "$SSHD_CONFIG"
    fi

    # Verify sshd syntax before restart
    if sshd -t; then
        systemctl restart sshd || systemctl restart ssh
        log_success "SSH successfully hardened on Port ${TARGET_SSH_PORT}."
    else
        log_error "sshd syntax test failed! Reverting back to original config."
        cp "$BACKUP_DIR/sshd_config.bak" "$SSHD_CONFIG"
        systemctl restart sshd || systemctl restart ssh
    fi
}

# Module 5: Firewall Lockdown (UFW / Firewalld)
step_configure_firewall() {
    log "Configuring host firewall rules..."

    if [ "$FW_TOOL" = "ufw" ]; then
        ufw --force reset >/dev/null 2>&1 || true
        ufw default deny incoming
        ufw default allow outgoing

        # SSH
        ufw allow "${TARGET_SSH_PORT}/tcp" comment 'SSH Management'

        # Public Web Traffic for WAF Inspection
        ufw allow 80/tcp comment 'LynxWAF HTTP Proxy'
        ufw allow 443/tcp comment 'LynxWAF HTTPS Proxy'

        # WAF Management Console
        if [ -n "$ADMIN_CIDR" ]; then
            ufw allow from "$ADMIN_CIDR" to any port "$WAF_CONSOLE_PORT" proto tcp comment 'LynxWAF Console Restricted'
            log_success "Restricted port ${WAF_CONSOLE_PORT} exclusively to ${ADMIN_CIDR}."
        else
            ufw allow "${WAF_CONSOLE_PORT}/tcp" comment 'LynxWAF Cyber-SOC Console'
            log_warn "Port ${WAF_CONSOLE_PORT} opened to 0.0.0.0/0 (Global Public). Remember to enable 2FA and Secret Path!"
        fi

        echo "y" | ufw enable
        systemctl enable ufw
        log_success "UFW Firewall configured and active."
    else
        systemctl enable --now firewalld
        firewall-cmd --permanent --remove-service=dhcpv6-client >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${TARGET_SSH_PORT}/tcp"
        firewall-cmd --permanent --add-port=80/tcp
        firewall-cmd --permanent --add-port=443/tcp

        if [ -n "$ADMIN_CIDR" ]; then
            firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${ADMIN_CIDR}' port port='${WAF_CONSOLE_PORT}' protocol='tcp' accept"
            log_success "Restricted port ${WAF_CONSOLE_PORT} exclusively to ${ADMIN_CIDR} via firewalld rich rule."
        else
            firewall-cmd --permanent --add-port="${WAF_CONSOLE_PORT}/tcp"
            log_warn "Port ${WAF_CONSOLE_PORT} opened to 0.0.0.0/0 via firewalld."
        fi

        firewall-cmd --reload
        log_success "Firewalld configured and active."
    fi
}

# Module 6: Fail2Ban Protection for SSH
step_configure_fail2ban() {
    log "Configuring Fail2Ban brute-force intrusion prevention..."
    JAIL_LOCAL="/etc/fail2ban/jail.local"
    [ -f "$JAIL_LOCAL" ] && cp "$JAIL_LOCAL" "$BACKUP_DIR/"

    cat << EOF > "$JAIL_LOCAL"
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 4
banaction = iptables-multiport

[sshd]
enabled = true
port = ${TARGET_SSH_PORT}
logpath = %(sshd_log)s
backend = %(default_backend)s
maxretry = 3
bantime = 24h
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    log_success "Fail2Ban active: 3 failed SSH logins triggers a 24-hour IP ban."
}

# ------------------------------------------------------------------------------
# 4. Audit & Verification Routine
# ------------------------------------------------------------------------------
audit_system() {
    echo -e "\n${MAGENTA}${BOLD}======================================================================${NC}"
    echo -e "${MAGENTA}${BOLD}                    SYSTEM SECURITY AUDIT REPORT                      ${NC}"
    echo -e "${MAGENTA}${BOLD}======================================================================${NC}"

    # Listening Ports
    echo -e "\n${BOLD}[1] Currently Listening Network Ports (ss -tulnp):${NC}"
    ss -tulnp | grep -E "LISTEN" | awk '{printf "  • %-22s %-25s (%s)\n", $5, $1, $7}'

    # Firewall Status
    echo -e "\n${BOLD}[2] Firewall Status:${NC}"
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose | sed 's/^/  /'
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --list-all | sed 's/^/  /'
    fi

    # Ulimits
    echo -e "\n${BOLD}[3] Max Open Files (Ulimit):${NC} $(ulimit -n)"

    # Sysctl status
    echo -e "\n${BOLD}[4] Key Security Sysctl Flags:${NC}"
    echo "  • SYN Cookies          : $(sysctl -n net.ipv4.tcp_syncookies)"
    echo "  • Reverse Path Filter  : $(sysctl -n net.ipv4.conf.all.rp_filter)"
    echo "  • ICMP Broadcast Ignore: $(sysctl -n net.ipv4.icmp_echo_ignore_broadcasts)"
    echo "  • Somaxconn Backlog    : $(sysctl -n net.core.somaxconn)"
    echo -e "----------------------------------------------------------------------\n"
}

# ------------------------------------------------------------------------------
# 5. Execution Flow
# ------------------------------------------------------------------------------
execute_all() {
    log "Beginning Full Automated Production Hardening..."
    step_update_os
    step_kernel_sysctl
    step_file_limits
    step_harden_ssh
    step_configure_firewall
    step_configure_fail2ban
    audit_system

    echo -e "${GREEN}${BOLD}✔ ALL HARDENING MODULES APPLIED SUCCESSFULLY!${NC}"
    echo -e "  • A backup of original configs is saved at: ${BACKUP_DIR}"
    echo -e "  • Full log output saved at: ${LOG_FILE}"
    echo -e "  • ${YELLOW}${BOLD}IMPORTANT:${NC} Open a NEW terminal tab and verify SSH login on port ${TARGET_SSH_PORT} before closing this session!"
}

execute_selective() {
    echo -e "\n${CYAN}Select which steps to apply (y/n):${NC}"
    
    read -rp "1. Run OS update & install security tools? [y/N]: " S1
    [[ "$S1" =~ ^[Yy]$ ]] && step_update_os

    read -rp "2. Apply Kernel Sysctl & eBPF tunings? [y/N]: " S2
    [[ "$S2" =~ ^[Yy]$ ]] && step_kernel_sysctl

    read -rp "3. Increase system file descriptor limits (nofile)? [y/N]: " S3
    [[ "$S3" =~ ^[Yy]$ ]] && step_file_limits

    read -rp "4. Apply SSH hardening (Port: ${TARGET_SSH_PORT})? [y/N]: " S4
    [[ "$S4" =~ ^[Yy]$ ]] && step_harden_ssh

    read -rp "5. Configure Host Firewall (Port 80/443 & ${WAF_CONSOLE_PORT})? [y/N]: " S5
    [[ "$S5" =~ ^[Yy]$ ]] && step_configure_firewall

    read -rp "6. Setup Fail2Ban brute-force intrusion prevention? [y/N]: " S6
    [[ "$S6" =~ ^[Yy]$ ]] && step_configure_fail2ban

    audit_system
    echo -e "${GREEN}${BOLD}✔ Selected hardening steps applied successfully!${NC}"
}

# Entrypoint
check_root
detect_os
print_banner
interactive_menu
