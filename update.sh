#!/usr/bin/env bash
# ==============================================================================
# LynxWAF Community Edition — One-Command In-Place Updater
# Repository: https://github.com/ones006/LynxWAF-CE
#
# Phases, in order:
#   1. Preflight   : compose engine, docker daemon, layout, free disk
#   2. Self-sync   : refresh update.sh and docker-compose.yml from GitHub, so a
#                    newer image can never run against a stack file that no
#                    longer matches its mounts
#   3. Snapshot    : record image ID + registry digest of every service BEFORE
#                    pulling (ce-latest is mutable: without this there is no
#                    way back to the image that was running)
#   4. Backup      : tar ./config and ./data/nginx (small, and the first things
#                    to break across a version step)
#   5. Pull        : fetch the tags referenced by .env
#   6. Recreate    : up -d, forced when the compose file changed this run
#   7. Validate    : container state, crash-loop detection, console port, the
#                    .ver actually running, and the licensed root-domain quota
#
# Usage:
#   sudo bash update.sh                 # normal in-place update
#   sudo bash update.sh --dry-run       # print the plan, change nothing
#   sudo bash update.sh --yes           # no confirmation prompt (automation)
#   sudo bash update.sh --no-backup     # skip the config/nginx backup
#   sudo bash update.sh --keep-compose  # never touch the local docker-compose.yml
#   sudo bash update.sh --db-backup     # also mysqldump lynxwaf_db (can be large)
#
# Exit codes: 0 updated or already current, 1 failure, 2 invalid usage.
# ==============================================================================

set -eo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

GITHUB_REPO="ones006/LynxWAF-CE"
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/main"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)" || true
[ -n "$SCRIPT_DIR" ] || { echo "[ERROR] Cannot resolve script directory." >&2; exit 1; }
cd "$SCRIPT_DIR"

ARGS=("$@")
DRY_RUN=false
ASSUME_YES=false
DO_BACKUP=true
DO_DB_BACKUP=false
KEEP_COMPOSE=false
COMPOSE_CHANGED=false

log_info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_step()    { echo -e "\n${BOLD}$*${NC}"; }
die()         { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
usage_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 2; }

on_error() {
    local line="$1"
    echo -e "${RED}[ERROR]${NC} Update aborted at update.sh line ${line}." >&2
    if [ -n "${SNAPSHOT_FILE}" ] && [ -f "${SNAPSHOT_FILE}" ]; then
        echo -e "         Pre-update image record: ${BOLD}${SNAPSHOT_FILE}${NC}" >&2
        echo -e "         Containers were left as-is; nothing was deleted." >&2
    fi
}
trap 'on_error $LINENO' ERR

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)      DRY_RUN=true; shift ;;
        --yes|-y)       ASSUME_YES=true; shift ;;
        --no-backup)     DO_BACKUP=false; shift ;;
        --db-backup)    DO_DB_BACKUP=true; shift ;;
        --keep-compose) KEEP_COMPOSE=true; shift ;;
        --help|-h)
            sed -n '2,30p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *) usage_error "Unknown option '$1' (see --help)" ;;
    esac
done

# ------------------------------------------------------------------------------
# 1. Preflight
# ------------------------------------------------------------------------------
log_step "[1/7] Preflight checks"

if [ ! -f "./docker-compose.yml" ]; then
    die "No docker-compose.yml in $(pwd). Run this updater from your LynxWAF install directory (default /opt/lynxwaf), or re-run the installer."
fi
if [ ! -f "./.env" ]; then
    die "No .env in $(pwd). The stack reads MYSQL_ROOT_PASSWORD and REDIS_PASSWORD from it, so compose cannot start without it."
fi

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
else
    die "Docker Compose command not found."
fi
log_info "Compose engine: $("${COMPOSE_CMD[@]}" version --short 2>/dev/null || echo 'unknown')"

if ! command -v docker >/dev/null 2>&1; then
    die "Docker CLI not found. This updater drives 'docker' for image snapshots and exec probes."
fi
if ! docker info >/dev/null 2>&1; then
    die "Cannot talk to the Docker daemon. Is it running (systemctl start docker) and is this user allowed to reach it?"
fi
log_success "Docker daemon reachable"

if [ "$(id -u)" != "0" ]; then
    log_warn "Not running as root: container inspection and bind-mount ownership checks may be limited."
fi

FREE_MB="$(df -Pm "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo '')"
if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt 1024 ]; then
    log_warn "Only ${FREE_MB} MB free on this filesystem. Image pulls need headroom; clean up before retrying if the pull fails."
else
    log_info "Free space on this filesystem: ${FREE_MB:-unknown} MB"
fi

# ------------------------------------------------------------------------------
# 2. Self-sync from the repository
# ------------------------------------------------------------------------------
log_step "[2/7] Syncing updater and stack file from GitHub"

fetch_checked() {
    # fetch_checked <url> <dest> <required-marker> -> 0 when a usable file landed
    local url="$1" dest="$2" marker="$3"
    rm -f "$dest"
    curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$dest" 2>/dev/null || return 1
    [ -s "$dest" ] || return 1
    grep -q "$marker" "$dest" || return 1
    return 0
}

UPDATE_TMP="$(mktemp "${TMPDIR:-/tmp}/lynxwaf-update.XXXXXX")"
if fetch_checked "${GITHUB_RAW}/update.sh" "$UPDATE_TMP" "In-Place Updater"; then
    if ! bash -n "$UPDATE_TMP" 2>/dev/null; then
        rm -f "$UPDATE_TMP"
        log_warn "Upstream update.sh failed the syntax check; continuing with the local copy."
    elif cmp -s "$UPDATE_TMP" "$SCRIPT_DIR/update.sh"; then
        rm -f "$UPDATE_TMP"
        log_success "update.sh is already current"
    elif [ "$DRY_RUN" = true ]; then
        rm -f "$UPDATE_TMP"
        log_info "A newer update.sh exists upstream (dry-run: not replaced)."
    elif [ "${LYNXWAF_UPDATE_RESYNC:-}" = "1" ]; then
        rm -f "$UPDATE_TMP"
        log_warn "Upstream update.sh still differs after a resync; continuing with this copy to avoid a restart loop."
    else
        cp -p "$SCRIPT_DIR/update.sh" "$SCRIPT_DIR/update.sh.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        mv "$UPDATE_TMP" "$SCRIPT_DIR/update.sh"
        chmod +x "$SCRIPT_DIR/update.sh"
        log_success "Updater refreshed to the upstream revision; restarting with the new copy."
        exec env LYNXWAF_UPDATE_RESYNC=1 LYNXWAF_KEEP_COMPOSE="${KEEP_COMPOSE}" bash "$SCRIPT_DIR/update.sh" "${ARGS[@]}"
    fi
else
    rm -f "$UPDATE_TMP"
    log_warn "Could not fetch update.sh from GitHub; continuing with the local copy."
fi

# Keep the stack files in step with upstream. The optional eBPF overlay is
# included so an install that predates it can enable the L4 datapath without
# hunting for the file.
sync_stack_file() {
    local name="$1"
    local tmp="${SCRIPT_DIR}/${name}.upstream"
    local local_path="${SCRIPT_DIR}/${name}"
    local was_present=false

    if ! fetch_checked "${GITHUB_RAW}/${name}" "$tmp" "lynxwaf-daemon"; then
        rm -f "$tmp"
        log_warn "Could not fetch ${name} from GitHub; continuing with the local copy."
        return
    fi

    if [ -f "$local_path" ] && cmp -s "$tmp" "$local_path"; then
        rm -f "$tmp"
        log_success "${name} matches upstream"
        return
    fi

    if [ "$KEEP_COMPOSE" = true ] || [ "${LYNXWAF_KEEP_COMPOSE:-}" = "true" ]; then
        rm -f "$tmp"
        log_warn "--keep-compose: local ${name} left untouched. If the new image needs a mount or variable that this file lacks, the stack will misbehave until you sync it."
        return
    fi

    if [ "$DRY_RUN" = true ]; then
        rm -f "$tmp"
        log_info "${name} differs from upstream (dry-run: not replaced)."
        return
    fi

    if [ -f "$local_path" ]; then
        was_present=true
        cp -p "$local_path" "${local_path}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    mv "$tmp" "$local_path"

    if [ "$was_present" = true ]; then
        log_success "${name} updated to upstream (previous copy kept as ${name}.bak.<timestamp>)"
    else
        log_success "${name} installed from upstream (it is opt-in; the stack only uses it when passed with -f or COMPOSE_FILE)"
    fi

    # Only a change to a file the running stack actually consumes needs a recreate.
    if [ "$name" = "docker-compose.yml" ]; then
        COMPOSE_CHANGED=true
    elif [ -n "${COMPOSE_FILE:-}" ] && printf '%s' "$COMPOSE_FILE" | grep -q "$name"; then
        COMPOSE_CHANGED=true
    fi
}

sync_stack_file "docker-compose.yml"
sync_stack_file "docker-compose.ebpf.yml"

# ------------------------------------------------------------------------------
# 3. Snapshot the images that are running now
# ------------------------------------------------------------------------------
log_step "[3/7] Recording the current image state (rollback anchor)"

TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
SNAPSHOT_FILE="${LOG_DIR}/pre-update-${TS}.txt"

env_value() {
    # env_value <KEY> <default> — reads a plain KEY=value line from .env
    local raw
    raw="$(grep -m1 -E "^$1=" ./.env 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]' || true)"
    [ -n "$raw" ] || raw="$2"
    printf '%s' "$raw"
}

DAEMON_IMAGE="$(env_value LYNXWAF_DAEMON_IMAGE ghcr.io/ones006/lynxwaf-daemon:ce-latest)"
OPENRESTY_IMAGE="$(env_value LYNXWAF_OPENRESTY_IMAGE ghcr.io/ones006/lynxwaf-openresty:ce-latest)"

image_field() {
    # image_field <ref> <Id|RepoDigests>
    docker image inspect -f "{{.$2}}" "$1" 2>/dev/null | head -n1 || true
}

image_digest() {
    # One pullable repo@sha256:... ref per line, ready to paste into .env
    docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$1" 2>/dev/null || true
}

{
    echo "# LynxWAF CE pre-update snapshot — ${TS}"
    echo "# daemon_image=${DAEMON_IMAGE}"
    echo "#   id=$(image_field "$DAEMON_IMAGE" Id)"
    echo "#   digest=$(image_digest "$DAEMON_IMAGE" | tr '\n' ' ')"
    echo "# openresty_image=${OPENRESTY_IMAGE}"
    echo "#   id=$(image_field "$OPENRESTY_IMAGE" Id)"
    echo "#   digest=$(image_digest "$OPENRESTY_IMAGE" | tr '\n' ' ')"
    echo "# version=$(docker exec lynxwaf-daemon cat /app/.ver 2>/dev/null || echo 'not-running')"
} > "$SNAPSHOT_FILE"

DAEMON_ID_BEFORE="$(image_field "$DAEMON_IMAGE" Id)"
OPENRESTY_ID_BEFORE="$(image_field "$OPENRESTY_IMAGE" Id)"
log_info "Snapshot written to ${SNAPSHOT_FILE}"

case "$DAEMON_IMAGE" in
    *:ce-latest|*@*) ;;
    *) log_warn ".env pins the daemon to '${DAEMON_IMAGE}'. 'compose pull' only refreshes a mutable tag, so a pinned version will NOT move with this updater." ;;
esac
case "$OPENRESTY_IMAGE" in
    *:ce-latest|*@*) ;;
    *) log_warn ".env pins the data plane to '${OPENRESTY_IMAGE}' (same caveat)." ;;
esac

# ------------------------------------------------------------------------------
# Confirmation
# ------------------------------------------------------------------------------
if [ "$DRY_RUN" = true ]; then
    log_step "Dry run stops here"
    echo -e "Would run: ${BOLD}${COMPOSE_CMD[*]} pull${NC}"
    echo -e "Would run: ${BOLD}${COMPOSE_CMD[*]} up -d --remove-orphans${NC}$([ "$COMPOSE_CHANGED" = true ] && echo ' (with --force-recreate)')"
    echo -e "Would back up: ./config and ./data/nginx$([ "$DO_DB_BACKUP" = true ] && echo ' and mysqldump lynxwaf_db')"
    exit 0
fi

if [ "$ASSUME_YES" != true ] && [ -t 0 ]; then
    echo -e "\nAbout to pull new images and recreate the LynxWAF containers in ${SCRIPT_DIR}."
    echo -e "WAF traffic blips for a few seconds while the data plane restarts."
    read -r -p "Continue? [y/N] " answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo -e "${YELLOW}Aborted by operator; nothing changed.${NC}"; exit 0 ;;
    esac
fi

# ------------------------------------------------------------------------------
# 4. Backup
# ------------------------------------------------------------------------------
log_step "[4/7] Backing up control-plane state"

BACKUP_DIR="${SCRIPT_DIR}/backups"
if [ "$DO_BACKUP" = true ]; then
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    bundle="${BACKUP_DIR}/pre-update-${TS}.tgz"
    tars=()
    if [ -d "./config" ]; then
        tars+=(config)
    fi
    if [ -d "./data/nginx" ]; then
        tars+=(data/nginx)
    fi
    if [ ${#tars[@]} -gt 0 ]; then
        tar -czf "$bundle" "${tars[@]}" 2>/dev/null || log_warn "Backup tar reported a problem (continuing)."
        if [ -s "$bundle" ]; then
            chmod 600 "$bundle"
            log_success "State backup: ${bundle} ($(du -sh "$bundle" 2>/dev/null | awk '{print $1}'))"
        else
            rm -f "$bundle"
            log_warn "Backup produced nothing; skipping."
        fi
    else
        log_warn "No ./config or ./data/nginx to back up."
    fi
else
    log_info "--no-backup given, skipping (the pre-update snapshot in logs/ still records image digests)."
fi

if [ "$DO_DB_BACKUP" = true ]; then
    dump="${BACKUP_DIR:-$SCRIPT_DIR/backups}/pre-update-${TS}-db.sql"
    mkdir -p "$(dirname "$dump")"
    if docker exec lynxwaf-mysql sh -c 'mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --no-tablespaces lynxwaf_db' > "$dump" 2>/dev/null; then
        chmod 600 "$dump"
        log_success "Database dump: ${dump} ($(du -sh "$dump" 2>/dev/null | awk '{print $1}'))"
    else
        rm -f "$dump"
        log_warn "mysqldump failed (is lynxwaf-mysql running?). Continuing."
    fi
fi

# ------------------------------------------------------------------------------
# 5. Pull
# ------------------------------------------------------------------------------
log_step "[5/7] Pulling updated container images from GHCR"
"${COMPOSE_CMD[@]}" pull

# ------------------------------------------------------------------------------
# 6. Recreate
# ------------------------------------------------------------------------------
log_step "[6/7] Recreating containers"
if [ "$COMPOSE_CHANGED" = true ]; then
    log_info "Compose file changed this run: forcing a full recreate so new mounts and variables apply."
    "${COMPOSE_CMD[@]}" up -d --remove-orphans --force-recreate
else
    "${COMPOSE_CMD[@]}" up -d --remove-orphans
fi

DAEMON_ID_AFTER="$(image_field "$DAEMON_IMAGE" Id)"
OPENRESTY_ID_AFTER="$(image_field "$OPENRESTY_IMAGE" Id)"
if [ "$DAEMON_ID_BEFORE" = "$DAEMON_ID_AFTER" ] && [ "$OPENRESTY_ID_BEFORE" = "$OPENRESTY_ID_AFTER" ]; then
    log_warn "Image IDs did not change — this install was already on the newest images for these tags."
fi

# ------------------------------------------------------------------------------
# 7. Validate
# ------------------------------------------------------------------------------
log_step "[7/7] Validating the running stack"

RESTARTS_BEFORE="$(docker inspect -f '{{.RestartCount}}' lynxwaf-daemon 2>/dev/null || echo 0)"

healthy=true
for attempt in $(seq 1 30); do
    running=0
    for name in lynxwaf-mysql lynxwaf-redis lynxwaf-daemon lynxwaf-openresty; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)" = "true" ]; then
            running=$((running + 1))
        fi
    done
    if [ "$running" -eq 4 ]; then
        break
    fi
    sleep 2
done
[ "$running" -eq 4 ] || healthy=false

if [ "$healthy" != true ]; then
    log_warn "Not all four containers reported running within 60s:"
    "${COMPOSE_CMD[@]}" ps || true
    log_warn "Recent daemon logs:"
    docker logs --tail 20 lynxwaf-daemon 2>&1 | tail -20 || true
    die "Update may be incomplete. Fix the stack (docker compose logs) or roll back using ${SNAPSHOT_FILE}."
fi
log_success "All four containers are running"

RESTARTS_AFTER="$(docker inspect -f '{{.RestartCount}}' lynxwaf-daemon 2>/dev/null || echo 0)"
if [ "${RESTARTS_AFTER:-0}" -gt "${RESTARTS_BEFORE:-0}" ]; then
    log_warn "Daemon has restarted ${RESTARTS_AFTER} times (was ${RESTARTS_BEFORE}) — check 'docker logs -f lynxwaf-daemon' for a crash loop."
fi

CONSOLE_PORT="$(env_value LYNXWAF_PORT 8379)"
if timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${CONSOLE_PORT}" 2>/dev/null; then
    log_success "Cyber-SOC console accepts connections on 127.0.0.1:${CONSOLE_PORT}"
else
    log_warn "Could not open 127.0.0.1:${CONSOLE_PORT} yet. The daemon may still be warming up; re-check with: docker compose ps"
fi

RUNNING_VERSION="$(docker exec lynxwaf-daemon cat /app/.ver 2>/dev/null || echo 'unknown')"
log_info "Version now running: ${BOLD}${RUNNING_VERSION}${NC}"

LIC_FILE="${SCRIPT_DIR}/config/lynxwaf.lic"
if [ -f "$LIC_FILE" ]; then
    quota="$(grep -oE '"max_domains"[[:space:]]*:[[:space:]]*[0-9]+' "$LIC_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)"
    tier="$(grep -oE '"tier"[[:space:]]*:[[:space:]]*"[^"]*"' "$LIC_FILE" 2>/dev/null | cut -d'"' -f4 || true)"
    if [ -n "$quota" ]; then
        if [ "$quota" = "0" ]; then
            log_info "License active: tier ${tier:-unknown} — unlimited root domains"
        else
            log_info "License active: tier ${tier:-unknown} — ${quota} root domain(s). A signed key keeps the number it was issued with."
        fi
    else
        log_warn "config/lynxwaf.lic exists but no max_domains value could be read."
    fi
else
    log_info "No license file: Community Edition default applies — 1 root domain, unlimited subdomains, 1 node."
    log_info "Existing sites above that allowance keep serving; only adding a NEW root domain is refused."
fi

"${COMPOSE_CMD[@]}" ps || true

echo -e "\n${GREEN}${BOLD}✔ LynxWAF Community Edition updated successfully!${NC}"
echo -e "${BOLD}Rollback${NC} (image that was running before this update):"
echo -e "  set LYNXWAF_DAEMON_IMAGE / LYNXWAF_OPENRESTY_IMAGE in .env to the"
echo -e "  @sha256 digest recorded in ${SNAPSHOT_FILE}"
echo -e "  then: ${COMPOSE_CMD[*]} up -d --force-recreate"
echo -e "${BOLD}Previous stack file${NC}: docker-compose.yml.bak.<timestamp> (if it was updated)"
echo ""
