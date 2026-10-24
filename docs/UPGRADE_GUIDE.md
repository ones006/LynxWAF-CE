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

If your install predates the hardened updater, re-run the one-line installer first — it
now refreshes `update.sh`, `uninstall.sh` and `test_poc_simulation.sh` on every run
instead of only when they are missing.

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

### What the hardened updater does

`update.sh` runs seven phases and stops with an actionable message instead of a
half-applied stack:

| Phase | Behaviour |
| --- | --- |
| 1. Preflight | Verifies `docker-compose.yml` and `.env` exist, finds the compose engine (v2 plugin or `docker-compose`), confirms the Docker daemon answers, warns on low free space. |
| 2. Self-sync | Refreshes `update.sh` and `docker-compose.yml` from GitHub. The privileged `docker-compose.ebpf.yml` is **no longer distributed or synced at all**: if a copy from an older release is present the updater leaves it untouched and warns that it can drift — regenerating it is an operator action (Troubleshooting F). Downloaded files must pass a content sanity check; the previous copies are kept as `*.bak.<timestamp>`. A replaced updater re-execs itself once. |
| 3. Snapshot | Writes image ID **and registry digest** of the daemon and data plane to `logs/pre-update-<timestamp>.txt` before anything is pulled. |
| 4. Backup | Tars `config/` and `data/nginx/` into `backups/pre-update-<timestamp>.tgz` (mode 600). Add `--db-backup` for a `mysqldump` of `lynxwaf_db`. |
| 5. Pull | `docker compose pull`. |
| 6. Recreate | `docker compose up -d --remove-orphans`, with `--force-recreate` when the compose file changed so new mounts and variables actually apply. |
| 7. Validate | Waits for all four containers, flags a daemon crash-loop (restart counter went up), probes the console port, prints the `/app/.ver` now running and the licensed root-domain allowance. |

Flags: `--dry-run` (plan only, changes nothing), `--yes` (no prompt, for automation),
`--no-backup`, `--db-backup`, `--keep-compose` (never touch the local stack file), `--help`.

### Rolling back

`ce-latest` is a mutable tag, so the digest recorded in phase 3 is your way back:

```bash
cd /opt/lynxwaf
# 1. read the pre-update digest
cat logs/pre-update-<timestamp>.txt
# 2. pin it in .env
#    LYNXWAF_DAEMON_IMAGE=ghcr.io/ones006/lynxwaf-daemon@sha256:<digest>
#    LYNXWAF_OPENRESTY_IMAGE=ghcr.io/ones006/lynxwaf-openresty@sha256:<digest>
# 3. recreate against the pinned image
docker compose up -d --force-recreate
```

If `.env` pins a fixed version tag (for example `:v26.10.24.2`) the updater tells you
that `pull` cannot move it; restore `ce-latest` in `.env` when you want rolling updates again.

### Note for existing CE installs — root-domain quota revision

From `v26.10.24.3` the Community Edition allowance is **1 root domain (unlimited
subdomains, 1 node)**, revised down from 5. Quota is counted per registrable domain
(eTLD+1), so `shop.example.com` and `api.example.com` share one slot with
`example.com`; a wildcard `*.example.com` site consumes the whole allowance.

* Sites already configured above the new limit **keep serving** — the check only runs
  when a *new* root domain would be added, so nothing is taken offline by an update.
* Adding or creating a site on a second root domain is refused until you delete a root
  domain or activate a license.
* A `.lic` issued before the revision keeps the number it was signed with (the quota
  lives inside the Ed25519-signed payload); the new limit applies to keys issued from
  now on.
* `update.sh` prints the operative number in phase 7, so you can confirm the state
  after every update.

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
