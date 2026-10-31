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

### F. "XDP datapath is not attached (the process lacks CAP_NET_ADMIN…)"

**Symptom:** on *Network Defense (L4)* the tiles read `—` / "Not measured — no datapath
attached", and saving a policy shows `configuration rejected: XDP datapath is not
attached … the rule was saved as policy only`.

**Why this is not a bug:** the default stack runs the control-plane daemon bridged,
as a non-root user, with every Linux capability dropped. Attaching an XDP program to a
network card needs `CAP_BPF` + `CAP_NET_ADMIN` in the host network namespace, so the
daemon cannot do it — and it says so instead of pretending the kernel is filtering.
Your L4 settings are stored and will take effect the moment a datapath is attached.

**To make the L4 datapath real**, write the opt-in overlay on this host and start the
daemon with it. The overlay is **not a file in this repository**: it grants the daemon
uid 0, `CAP_BPF` + `CAP_NET_ADMIN` and the host network namespace, so a privileged
artefact must never reach a server through an installer, an update sync or a
`git clone`. You generate it deliberately, and it stays inert until you pass it with
`-f`.

Recommended — ask the image you already run for its own overlay, so the text cannot be
out of date (needs `lynxwaf-daemon` `v26.10.24.5` or newer):

```bash
cd /opt/lynxwaf
docker compose run --rm --no-deps lynxwaf-daemon ebpf --overlay > docker-compose.ebpf.yml
chmod 600 docker-compose.ebpf.yml
sudo docker compose -f docker-compose.yml -f docker-compose.ebpf.yml up -d --force-recreate lynxwaf-daemon
```

On an older image, or on an air-gapped host, save this block as `docker-compose.ebpf.yml`
yourself. It is the effective content of the generated file (the generated one adds a
comment header with the same consequences listed below), and CI re-validates it against
the base stack on every push — so a typo here fails the pipeline instead of your server:

<!-- LYNXWAF-XDP-OVERLAY-START: kept in sync with modules/ebpf_overlay.go -->
```yaml
services:
  lynxwaf-daemon:
    network_mode: "host"
    user: "0:0"
    volumes:
      - ./ssl:/app/ssl:rw
    # Only what an XDP attach needs: CAP_BPF to load the program, CAP_NET_ADMIN to
    # hook it onto the NIC. NET_RAW, DAC_OVERRIDE, SETUID, SETGID and NET_BIND_SERVICE
    # are absent on purpose — the process is already uid 0, so they would only widen
    # the blast radius.
    cap_drop:
      - ALL
    cap_add:
      - BPF
      - NET_ADMIN
      - SYS_ADMIN
    # Kernels before 5.11 account BPF memory against RLIMIT_MEMLOCK.
    ulimits:
      memlock: -1
    environment:
      # Quoted as strings: the base file declares these as KEY=value strings, and
      # podman-compose refuses to merge an int over a string.
      DB_HOST: 127.0.0.1
      DB_PORT: "33060"
      MYSQL_HOST: 127.0.0.1
      MYSQL_PORT: "33060"
      REDIS_HOST: 127.0.0.1
      REDIS_PORT: "6379"
      # The coordination listener, not the engine's public port. The base file
      # defaults this to http://host.docker.internal, which does not resolve once the
      # daemon shares the host namespace, and 127.0.0.1 reaches only the protected
      # sites — the console-to-engine endpoints live on 127.0.0.251.
      WAF_ENGINE_URL: http://127.0.0.251
      # Absolute path inside the image; the loader validates it before use.
      LYNXWAF_XDP_OBJECT: /app/ebpf/xdp_filter.o
```
<!-- LYNXWAF-XDP-OVERLAY-END -->

`update.sh` no longer refreshes this file, because upstream no longer distributes it. If
you keep a copy, keeping it current is your call: regenerate it, `diff` it against yours,
then replace it deliberately.

Then reload *Network Defense (L4)*: the interface list now shows the host NICs, and
after enabling mitigation the status becomes `ATTACHED` with live counters.

Understand what the overlay does before you enable it. The daemon joins the host network
namespace (the console listens on port 8379 directly, the base `ports:` mapping is
ignored **and `LYNXWAF_BIND_IP` no longer restricts it** — bind the console to a
firewall or a reverse proxy first), MySQL/Redis are reached through their published
loopback ports, the process runs as root so files under `config/`, `logs/` and `data/`
become root-owned, and XDP drops happen before netfilter — keep SSH and the console port
in the allowed TCP list or you can lock yourself out.

**Still unavailable with the overlay?** The kernel or virtual NIC is the limit, not
the container:

```bash
# Kernel without BTF/XDP support (common on managed/shared hosts)
uname -r; ls /sys/kernel/btf/vmlinux 2>/dev/null || echo "no BTF"
# Driver without native XDP: switch the console to "XDP Generic"
sudo ip link set dev eth0 xdp off   # clears a program that blocks the attach
```

### G. The Traffic Chart Stays Empty on a Live Proxy

Sites are served, requests are logged in `access.log`, and yet the console's QPS and
total-request panels stay flat. Nothing is broken in the data path: the counters live in
the engine and the console has to be able to read them.

In this stack the engine runs with `network_mode: host`, so the coordination listener on
`127.0.0.251:80` is bound to the **host's** loopback — while the console container sits on
the Compose bridge and owns a different loopback. That address is not reachable from the
daemon container, so the counters are mirrored instead: an engine worker writes
`data/nginx/conf.d/waf/data/lynxwaf_global_status.json` every few seconds
over the journal volume, and the console reads that file when the HTTP read fails.
Configuration changes travel the same way in reverse: the daemon writes
`lynxwaf_reload.json` into that directory and the engine's supervisor process applies it —
the daemon container has no docker CLI, no nginx binary, and no permission to signal a
root-owned master. If you followed §F to put the daemon on the host network as well, the
HTTP read works directly and the mirror is only a second source — that overlay is the
reason `WAF_ENGINE_URL: http://127.0.0.251` belongs with it.

```bash
# 1. Is the engine exporting? A fresh timestamp means the worker timer is armed.
ls -l --time-style=full-iso /opt/lynxwaf/data/nginx/conf.d/waf/data/lynxwaf_global_status.json

# 2. Is the exporter loaded at all? It lives in the generated waf.conf.
grep -c 'init_worker_by_lua' /opt/lynxwaf/data/nginx/conf.d/waf/waf.conf

# 3. Can the console ask for a reload? Same volume, daemon side, must be writable by uid 1000.
docker exec -u 1000:1000 lynxwaf-daemon sh -c \
  'p=/app/data/nginx/conf.d/waf/data/.probe; : > "$p" && rm -f "$p" && echo writable'

# 4. Does the engine have anything to read that reload with? Older engine images do not.
docker exec lynxwaf-openresty sh -c \
  'test -x /opt/lynxwaf/bin/lynxwaf-engine.sh && echo supervisor present || echo NO SUPERVISOR - engine is too old to reload'

# 5. Can the engine write its own journal? /etc/nginx is read-only by design and only this
#    directory inside it is writable; a container created before that mount landed cannot
#    export anything.
docker exec lynxwaf-openresty sh -c \
  'p=/etc/nginx/waf/data/.probe; : > "$p" && rm -f "$p" && echo writable || echo JOURNAL READ-ONLY'
```

Step 4 and 5 failing together, or either one alone, is the half-updated stack: the console
moved to the new image and the data plane did not, which is exactly what an interrupted
`update.sh` leaves behind. `docker compose ps` still reports four healthy containers, so
nothing announces the problem. `docker compose pull lynxwaf-openresty` then
`docker compose up -d lynxwaf-openresty` fixes it; the container recreates because its
image id changed, and the new one carries the supervisor and the read-write journal mount.

If step 1 shows the file missing or minutes old while step 2 prints `1`, the engine is
still running the configuration it loaded at container start — the engine comes up while
the daemon is still generating that file, so after an update it can be one version behind.
One reload closes the gap:

```bash
cd /opt/lynxwaf
docker compose exec lynxwaf-openresty nginx -t && docker compose exec lynxwaf-openresty nginx -s reload
```

If step 3 fails, the shared journal is root-owned, and then no configuration change can
reach the engine either — that one directory carries the reload requests, the counters and
the interception log. Fix the ownership:

```bash
chown -R 1000:1000 /opt/lynxwaf/data && docker compose restart lynxwaf-daemon lynxwaf-openresty
```

An unwritable journal on the **engine** side is the same ownership problem seen from the
other container, and it used to be invisible: the exporter tried, failed, remembered the
failure and said nothing for the life of the worker. It now logs once per worker, so the
engine answers the question directly:

```bash
tail -n 20 /opt/lynxwaf/data/nginx/logs/error.log | grep 'counter mirror'
```

A reload can also be refused rather than skipped. The supervisor runs `nginx -t` before
signalling and keeps serving the current configuration if the generated one does not
validate, so check the engine's own output before suspecting the channel:

```bash
docker logs lynxwaf-openresty 2>&1 | grep -i 'refused reload'
```

A stale first data point is normal: the console stores a per-minute delta, so the initial
sample is only a baseline. Give it two minutes after the mirror starts moving.

### H. The Update Cannot Reach GHCR (Offline Update)

`docker compose pull` fails with `net/http: TLS handshake timeout` while this still
succeeds:

```bash
ping -c 2 ghcr.io
```

ICMP proves a route, not a registry session. The decisive test is a request, and if it
times out at connect time the destination is blocked on the path — a router, the ISP or a
LAN firewall — rather than in Docker:

```bash
curl -sS -o /dev/null --max-time 15 -w '%{http_code} %{time_total}s\n' https://ghcr.io/v2/
```

A healthy answer from anywhere else is `401`: that endpoint requires a token. `000` after
15 s means no TCP connection was ever made. Confirm the host's own firewall is not the
cause (`sudo ufw status`) and check for a proxy the daemon might be using, which the shell
does not:

```bash
systemctl show docker -p Environment; cat /etc/docker/daemon.json 2>/dev/null
```

If a proxy exists, pointing the daemon at it is the permanent fix. If there is none, update
from an image archive. On any machine that can reach GHCR:

```bash
docker pull ghcr.io/ones006/lynxwaf-daemon:ce-latest
docker pull ghcr.io/ones006/lynxwaf-openresty:ce-latest
docker save -o lynxwaf-ce-$(date +%Y.%m.%d)-amd64.tar \
  ghcr.io/ones006/lynxwaf-daemon:ce-latest \
  ghcr.io/ones006/lynxwaf-openresty:ce-latest
```

The archive carries the tag names, and the host loads them verbatim: they must be the
exact values of `LYNXWAF_DAEMON_IMAGE` and `LYNXWAF_OPENRESTY_IMAGE` in the host's `.env`
(`ce-latest` unless it was pinned). Save the pinned tag instead if that is what `.env` asks
for.

Then on the host:

```bash
ssh admin@host 'mkdir -p /opt/lynxwaf/offline'
scp lynxwaf-ce-*.tar admin@host:/opt/lynxwaf/offline/   # or copy by USB
cd /opt/lynxwaf && sha256sum offline/*.tar && sudo bash update.sh --offline
```

`--offline` loads the newest archive in `./offline/` (or the one given as
`--offline=/path/to.tar`), skips the registry entirely, and then reuses every other phase
of the updater: snapshot, backup, recreate and validation. It refuses to continue if the
archive does not carry the exact tags `.env` asks for, because compose would otherwise
recreate from whatever older image happened to be local and report success.

A first install on the same blocked path uses the same archive:

```bash
cd /opt/lynxwaf && sudo bash install.sh --offline
```

`install.sh --offline` also loads `./offline/*.tar` (or `--offline=/path/to.tar`) and
verifies that both images named in `.env` are present before it starts anything. A missing
tag fails the install rather than sending compose back to the registry, so the archive has
to be saved from the same tags the host expects.

Two things are worth checking afterwards, because an offline host is exactly the case where
a stale cached image can be reused without complaint:

```bash
docker exec lynxwaf-openresty sh -c 'test -x /opt/lynxwaf/bin/lynxwaf-engine.sh && echo supervisor-present'
docker top lynxwaf-openresty | head -3   # PID 1 must be lynxwaf-engine.sh, not nginx
```

If the supervisor is missing, the engine predates the reload channel: the console will save
configuration changes and nothing will apply them.

### I. Every Reload Is Refused (`directive is duplicate`)

Sites appear in the console, their vhost files exist under `data/nginx/conf.d/vhost/`, but
`https://` does not connect at all and `http://` still answers with the default welcome page.
The engine log repeats the same verdict every two seconds:

```bash
docker logs lynxwaf-openresty 2>&1 | tail -20
# nginx: [emerg] "client_max_body_size" directive is duplicate in /etc/nginx/user/<site>.conf:14
# lynxwaf: refused reload, the generated configuration does not validate
```

Each site vhost includes its own operator snippet (`/etc/nginx/user/<site_id>.conf`) inside
its server block. Older installs additionally included the whole `user/` directory in the
engine's `http` block, where a snippet setting `client_max_body_size` duplicates the one
already defined there — and nginx refuses the entire configuration, so the engine keeps
serving the one it booted with and no site ever appears. The same glob also applied one
site's `add_header` (for example its Content-Security-Policy) to every other site.

Remove the http-level include once, then reload:

```bash
sudo sed -i '/include \/etc\/nginx\/user\/\*\.conf;/d' /opt/lynxwaf/data/nginx/conf/nginx.conf
sudo docker exec lynxwaf-openresty nginx -t
sudo docker exec lynxwaf-openresty nginx -s reload
```

`nginx -t` must print `syntax is ok` and `test is successful`; the reload then binds 443 and
the pending sites serve immediately. `install.sh` no longer writes that line, and `update.sh`
repairs a host that still carries it: it keeps a timestamped copy beside the file, removes the
line, and runs `nginx -t` inside the engine, restoring the copy if the result does not
validate. Run the manual commands above only when the updater reports that it could not.

---

## 3. Full Clean Restart

To safely reboot the entire LynxWAF stack:

```bash
cd /opt/lynxwaf
docker compose down
docker compose up -d
```
*(Your configurations and certificates in `/opt/lynxwaf/config` and `/opt/lynxwaf/data` are persistent and will not be lost).*
