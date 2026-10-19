# LynxWAF Community Edition — Quick Start Guide

Welcome to **LynxWAF Community Edition (CE)**! This guide will walk you through deploying and configuring your Web Application Firewall in under 5 minutes.

---

## 1. System Requirements

| Specification | Minimum Requirement | Recommended for Production |
| :--- | :--- | :--- |
| **Operating System** | Ubuntu 20.04+, Debian 11+, CentOS 7+, Rocky/AlmaLinux 8+ | Ubuntu 22.04 LTS / Debian 12 |
| **CPU Architecture** | x86_64 / amd64 or aarch64 / arm64 | 2+ Cores |
| **RAM** | 1 GB Free Memory | 2 GB+ RAM |
| **Disk Space** | 5 GB Free Disk Space | 20 GB+ NVMe SSD |
| **Network Ports** | 80/tcp (HTTP), 443/tcp (HTTPS), 8379/tcp (Console) | Dedicated Public IPv4/IPv6 |

---

## 2. Firewall Prerequisites

Ensure ports `80`, `443`, and `8379` are open on your host firewall:

### On Ubuntu / Debian (UFW):
```bash
sudo ufw allow 80/tcp comment 'HTTP Proxy'
sudo ufw allow 443/tcp comment 'HTTPS Proxy'
sudo ufw allow 8379/tcp comment 'LynxWAF Cyber-SOC Console'
sudo ufw reload
```

### On CentOS / RHEL / Rocky / AlmaLinux (Firewalld):
```bash
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --permanent --add-port=8379/tcp
sudo firewall-cmd --reload
```

---

## 3. Automated 1-Line Installation (Recommended)

Run the automated quick installer on your server with root privileges:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ones006/LynxWAF-CE/main/install.sh)"
```

### What the installer handles automatically:
1. Detects OS distribution and CPU architecture (`amd64` / `arm64`).
2. Validates RAM and port availability.
3. Automatically installs Docker Engine and Docker Compose v2 if not already present.
4. Generates cryptographically secure, random 24-character database and session passwords in `.env`.
5. Pulls official hardened container images from GitHub Container Registry (`ghcr.io`).
6. Starts the container stack via `docker compose up -d`.
7. Provisions the default administrator user (`admin`).

---

## 4. Manual Deployment via Git Clone

If you prefer full control over repository files:

```bash
# 1. Clone repository
git clone https://github.com/ones006/LynxWAF-CE.git /opt/lynxwaf
cd /opt/lynxwaf

# 2. Copy and configure environment variables
cp .env.example .env

# 3. Create persistent directories
mkdir -p config data/mysql/data data/mysql/log data/nginx/logs data/nginx/conf data/nginx/conf.d data/wwwroot logs

# 4. Start the stack
docker compose up -d

# 5. Provision the initial admin user
docker exec -it lynxwaf-daemon /app/LynxWaf create_default_user admin "YourStrongPassword2026!"
```

---

## 5. Accessing the Management Console

Once installation finishes, open your browser and navigate to:
```
https://<YOUR_SERVER_IP>:8379
```

> **Note on TLS Certificate Warning:**  
> LynxWAF initializes with a self-signed HTTPS certificate for management traffic security. It is completely safe to accept the browser security prompt on first launch.

- **Username**: `admin`
- **Password**: *(Check the generated password shown at the end of the installation, or stored in `/opt/lynxwaf/.env`)*

---

## 6. Onboarding Your First Protected Website

1. Log in to the LynxWAF Web Console.
2. Go to **Sites ➔ Add Protected Site**.
3. Fill in your website configuration:
   - **Domain**: `example.com` (and `www.example.com`)
   - **Upstream Type**: HTTP / HTTPS
   - **Upstream Backend**: `http://192.168.1.50:8080` (or `http://127.0.0.1:8080` if upstream runs locally)
   - **Defense Mode**: **Blocking** (Actively blocks attacks) or **Monitoring** (Logs attacks without blocking)
   - **SSL / TLS**: Toggle **Auto-Issue Let's Encrypt** for automatic free HTTPS certificates.
4. Click **Save & Deploy**.
5. Update your domain DNS A Record to point to the LynxWAF Server IP.

---

## 7. Verifying WAF Defense

Test whether LynxWAF is properly intercepting attacks using our automated PoC test suite:

```bash
cd /opt/lynxwaf
./test_poc_simulation.sh https://<YOUR_SERVER_IP_OR_DOMAIN>
```

You should see immediate `403 Forbidden` interception responses across SQLi, XSS, RCE, and malicious scanner tests!
