# LynxWAF Community Edition — Troubleshooting Guide

This guide covers common issues, diagnostics, and recovery procedures for **LynxWAF Community Edition**.

---

## 1. Quick Diagnostic Commands

Always check service status and logs first when encountering issues:

```bash
cd /opt/lynxwaf

# Check running status of all containers
docker compose ps

# View live error logs from the WAF Data Plane
docker compose logs -f lynxwaf-openresty

# View live logs from the Control Plane & Management Console
docker compose logs -f lynxwaf-daemon

# Check database and cache status
docker compose logs lynxwaf-mysql
docker compose logs lynxwaf-redis
```

---

## 2. Common Issues & Solutions

### A. Port 80 or 443 Conflict
**Symptom**: `docker compose up` fails with:
`Error starting userland proxy: listen tcp4 0.0.0.0:80: bind: address already in use`

**Cause**: An existing web server (such as default Apache, Nginx, or Caddy) is running on the host system.

**Resolution**:
1. Identify the process holding port 80 or 443:
   ```bash
   sudo ss -tulpn | grep -E ':80|:443'
   ```
2. Disable and stop the competing service:
   ```bash
   # For Apache
   sudo systemctl stop apache2 && sudo systemctl disable apache2
   # or
   sudo systemctl stop httpd && sudo systemctl disable httpd

   # For standalone Nginx
   sudo systemctl stop nginx && sudo systemctl disable nginx
   ```
3. Restart LynxWAF:
   ```bash
   docker compose up -d
   ```

---

### B. Resetting Lost Administrator Password
**Symptom**: You forgot the web console administrator password.

**Resolution**:
You can reset the password directly via the CLI without restarting containers:

```bash
docker exec -it lynxwaf-daemon /app/LynxWaf reset_password "YourNewStrongPassword123!"
```
Log in immediately at `https://<YOUR_IP>:8379` with username `admin` and your new password.

---

### C. 502 Bad Gateway Error on Protected Websites
**Symptom**: Visiting your protected site returns `502 Bad Gateway`.

**Causes & Fixes**:
1. **Origin web server is down**: Ensure your upstream application (Node.js, PHP-FPM, Docker container) is running and accepting connections.
2. **Localhost network isolation**: If your upstream runs on the host system (outside Docker), use the host's actual internal IP address (e.g., `192.168.1.50:8080` or `172.17.0.1:8080`) rather than `localhost:8080` or `127.0.0.1:8080`.
3. **Firewall blocking upstream**: Verify that your server firewall allows LynxWAF to connect to the upstream backend port.

---

### D. Let's Encrypt Certificate Issuance Failed
**Symptom**: Automatic SSL certificate generation stays pending or fails.

**Verification Checklist**:
1. **Public DNS**: Run `dig +short yourdomain.com` from an external network to verify that DNS points directly to your LynxWAF public IP.
2. **Port 80 Accessible**: Let's Encrypt validates domain ownership via HTTP-01 challenge over port 80. Ensure port 80 is not blocked by your cloud security group (AWS SG, GCP Firewall, Cloudflare proxy, etc.).
3. **CAA Record**: Ensure your domain DNS does not have a restrictive CAA record blocking Let's Encrypt (`letsencrypt.org`).

---

### E. Database Container Fails to Start
**Symptom**: `lynxwaf-mysql` keeps restarting or reports health check failure.

**Resolution**:
1. Check available disk space:
   ```bash
   df -h /opt/lynxwaf
   ```
   MySQL requires at least 2 GB of free disk space to initialize the data directory.
2. Check file permissions:
   ```bash
   sudo chown -R 999:999 /opt/lynxwaf/data/mysql
   docker compose restart lynxwaf-mysql
   ```

---

## 3. Full Clean Restart

To safely reboot the entire LynxWAF stack:

```bash
cd /opt/lynxwaf
docker compose down
docker compose up -d
```
*(Your configurations and certificates in `/opt/lynxwaf/config` and `/opt/lynxwaf/data` are persistent and will not be lost).*
