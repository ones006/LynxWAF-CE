# LynxWAF Community Edition — Configuration Guide

This document covers operational configurations for managing reverse proxy upstreams, SSL certificates, defense rules, and rate limiting in **LynxWAF Community Edition**.

---

## 1. Reverse Proxy & Upstream Routing

LynxWAF acts as an inline Layer 7 reverse proxy sitting in front of your origin web applications (WordPress, Laravel, Node.js, Spring Boot, etc.).

### Upstream Modes:
1. **Single Backend Server**:
   - `http://10.0.0.15:8080`
2. **Multiple Backend Servers (Load Balanced)**:
   - Round-Robin, Least Connections, or IP-Hash sticky sessions across multiple internal IP targets:
     - `http://10.0.0.15:8080` (weight: 1)
     - `http://10.0.0.16:8080` (weight: 1)
3. **Local Origin Co-location**:
   - If your application server runs on the same physical host, bind your application to a loopback port (e.g., `127.0.0.1:8000`) and configure the upstream in LynxWAF as `http://127.0.0.1:8000`.

---

## 2. SSL/TLS Certificate Management

### A. Automated Let's Encrypt (ACME Engine)
- LynxWAF features an embedded ACME client that requests and renews Let's Encrypt certificates automatically over HTTP-01 challenge.
- **Requirements**:
  - Your domain's DNS A/AAAA records must resolve to the public IP of your LynxWAF server.
  - Port `80` must be accessible from the public internet.
- **Renewal**: Certificates are verified and automatically renewed 30 days before expiration without downtime.

### B. Custom Enterprise / Wildcard SSL Upload
If you use commercial SSL certificates (DigiCert, Sectigo, Cloudflare Origin CA) or internal corporate PKI:
1. Open **Sites ➔ Site Configuration ➔ SSL/TLS Settings**.
2. Select **Upload Custom Certificate**.
3. Paste or upload the full certificate chain (`fullchain.pem` or `.crt`) and the private key (`privkey.key` or `.key`).
4. Click **Apply Changes**. OpenResty reloads TLS keys in memory via Lua without dropping active keepalive connections.

---

## 3. Defense Engines & Inspection Modules

LynxWAF Community Edition includes three core inspection engines:

### 1. Semantic AST Inspection Engine
Unlike traditional regex-only WAFs that are easily bypassed by character encoding or comment tricks (`/**/`), LynxWAF parses incoming payloads into Abstract Syntax Trees (AST) to evaluate real semantic execution risk:
- **SQL Injection (SQLi)**: Detects boolean tautologies, stacked queries, union extractions, and out-of-band channels.
- **Cross-Site Scripting (XSS)**: Evaluates script tags, DOM attributes (`onload`, `onerror`), and JavaScript protocol injections.
- **Remote Code Execution (RCE)**: Blocks shell pipes, backtick execution, and binary invocation probes.
- **Path Traversal / LFI**: Intercepts `../` directory climbing and sensitive OS file paths (`/etc/passwd`, `/etc/shadow`, `boot.ini`).

### 2. Silent Anti-Bot Proof-of-Work (PoW)
- Replaces annoying human CAPTCHA puzzles with an invisible, background mathematical challenge computed by client browsers.
- Legitimate users experience zero friction (verification finishes in ~50ms).
- Automated scrapers, credential stuffers, and headless bots fail the computational challenge and are stopped immediately.

### 3. IP Access Control (Blacklist & Whitelist)
- **Whitelist**: Bypass inspection for internal office IPs, trusted VPN endpoints, or synthetic monitoring probes.
- **Blacklist**: Drop connections from malicious IPs or entire CIDR subnets (`198.51.100.0/24`).

---

## 4. Rate Limiting & CC Flood Defense

To prevent aggressive scrapers and HTTP request floods:
- Set per-IP rate limits (e.g., maximum 50 requests per second per IP).
- Enable burst buffering to accommodate legitimate spike traffic.
- Configure automatic temporary bans (e.g., auto-ban IP for 10 minutes if threshold is exceeded).

---

## 5. Defense Modes

Every site in LynxWAF can operate in one of two modes:

| Mode | Behavior | Best Used For |
| :--- | :--- | :--- |
| **Protecting (Active)** | Threats are intercepted immediately with a `403 Forbidden` response. | Production environments. |
| **Monitoring (Passive)** | Threats are logged and alerted in real-time without blocking the user. | Staging / testing to identify false positives. |
