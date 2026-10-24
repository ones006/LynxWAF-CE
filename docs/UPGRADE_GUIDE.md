# LynxWAF Community Edition — Upgrade & License Activation Guide

This guide describes how to update LynxWAF Community Edition to newer releases and how to seamlessly activate Sovereign Edition.

---

## 1. Updating Community Edition to Latest Version

Updating LynxWAF Community Edition is fast, non-destructive, and requires no manual compilation.

### Option A: Using the Automated Updater Script
```bash
cd /opt/lynxwaf
sudo bash update.sh
```

### Option B: Using Standard Docker Compose Commands
```bash
cd /opt/lynxwaf

# 1. Pull the latest container images from GHCR
docker compose pull

# 2. Re-create containers with updated images
docker compose up -d --remove-orphans

# 3. Verify status
docker compose ps
```

> **Data Safety Guarantee:**  
> All your site configurations, SSL certificates, custom rules, and telemetry logs reside in persistent host directories (`config/` and `data/`). They are **fully preserved across updates**.

---

## 2. Upgrading to Sovereign Edition

LynxWAF Community Edition has built-in forward compatibility with the Sovereign Edition. **No reinstall or server migration is required.**

### Sovereign Feature Highlights:
- **Unlimited Protected Domains** (removes the 1-root-domain CE limit; Professional Edition covers 15 root domains before you need Sovereign).
- **Multi-Node Active-Active HA Cluster** (Geo-Mesh Redis sync & VRRP keepalived).
- **Kernel eBPF / XDP L4 Anti-DDoS** (Wire-speed <100ns packet dropping in Linux Ring 0).
- **Outbound DLP Compliance Engine** (Automatic masking of NIK, Credit Cards, Bank Accounts under UU PDP No. 27/2022).
- **Automated Compliance PDF Generator** (Official audit reports for PCI-DSS v4.0, ISO 27001, and SOC 2).
- **White-Labeling & Reseller Branding** (Custom vendor logo, favicon, color themes for MSPs).
- **Dedicated Support SLA**.

---

### Step-by-Step License Activation:

1. Request your signed license file (`lynxwaf.lic`) by contacting us via Telegram [**@onelynxs**](https://t.me/onelynxs) or email `ones006@gmail.com`.
2. Log in to your existing Community Edition console:
   ```
   https://<YOUR_SERVER_IP>:8379
   ```
3. Navigate to **Settings ➔ License & Cryptography**.
4. Upload your `lynxwaf.lic` file or paste the signed Ed25519 JSON token into the activation box.
5. Click **Verify & Activate**.
6. **Result**: All Sovereign modules activate **instantly in memory without downtime or container restarts!**
