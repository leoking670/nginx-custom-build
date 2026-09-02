#!/bin/bash
#   from a signed GitHub Release and swaps it in on this host.
#   It inherits the legacy script's single-instance lock / circuit breaker /
#   smooth-upgrade-with-rollback, and adds signature verification + an ldd check.
#
# ==== one-time setup (root, manual) ====
#  1. Set REPO below to your GitHub repo "OWNER/REPO" (public releases need no token).
#  2. Import the public key that matches the private key used in CI:
#     gpg --export <KEYID> > /etc/nginx-update/nginx-signer.asc
#     gpg --no-default-keyring --keyring /usr/share/keyrings/nginx-signer.gpg \
#         --import /etc/nginx-update/nginx-signer.asc
#  3. Add to cron:  0 4 * * * /path/to/deploy.sh   (VPS local time)
#
set -euo pipefail

# ===== config =====
readonly REPO="OWNER/REPO"              # edit this: your GitHub repo
readonly NGINX_PREFIX="/usr/local/nginx"
readonly NGINX_USER="nginx"
readonly LOG_FILE="/var/log/nginx-auto-update.log"
readonly LOG_MAX_LINES=5000
readonly CIRCUIT_BREAKER="/var/lib/nginx-update-breaker"
readonly BACKUP_DIR="/usr/local/nginx-backups"
readonly MAX_BACKUPS=3
readonly CURL_OPTS="--connect-timeout 10 --max-time 120 --retry 3 -fsSL"
readonly KEYRING="/usr/share/keyrings/nginx-signer.gpg"
readonly MARKER="$NGINX_PREFIX/.current_version"
readonly BUILD_DIR="/tmp/nginx-build"
readonly RUNTIME_PKGS="zlib1g libpcre2-8-0 libjemalloc2"   # zstd/brotli are static, not needed

# ===== preflight =====
[[ $EUID -ne 0 ]] && { echo "root required"; exit 1; }
for cmd in jq gpgv curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "required command missing: $cmd (apt install jq gpg gnupg2)"; exit 1; }
done

# ===== single-instance lock =====
exec 200>/var/lock/nginx-update.lock
flock -n 200 || { echo "another instance is running"; exit 1; }

# ===== helpers =====
WORK="$BUILD_DIR/nginx-update"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

log() { echo "[$(date '+%F %T')] [$1] ${*:2}" >> "$LOG_FILE" || true; }

fatal() {
    touch "$CIRCUIT_BREAKER"
    log ERROR "circuit breaker: $1"
    echo "circuit breaker set: $1 (file created at $CIRCUIT_BREAKER; delete it after fixing)" >&2
    exit 1
}

manage_log() {
    [[ -f "$LOG_FILE" && $(wc -l < "$LOG_FILE") -gt $LOG_MAX_LINES ]] && {
        tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
    } || true
}

mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR" "$(dirname "$CIRCUIT_BREAKER")" "$(dirname "$KEYRING")"
manage_log
[[ -f "$CIRCUIT_BREAKER" ]] && { log ERROR "circuit breaker already set: $CIRCUIT_BREAKER"; exit 1; }

# ===== user & deps (idempotent) =====
if ! getent group "$NGINX_USER" >/dev/null 2>&1; then
    groupadd -r "$NGINX_USER"
    log INFO "created group: $NGINX_USER"
fi
if ! getent passwd "$NGINX_USER" >/dev/null 2>&1; then
    useradd -r -g "$NGINX_USER" -s /sbin/nologin -d /nonexistent "$NGINX_USER"
    log INFO "created user: $NGINX_USER"
fi

mkdir -p /var/cache/nginx/{client_temp,proxy_temp,fastcgi_temp,uwsgi_temp,scgi_temp} /etc/nginx /run/lock
chown -R "$NGINX_USER:$NGINX_USER" /var/cache/nginx

missing_pkgs=()
for pkg in $RUNTIME_PKGS; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing_pkgs+=("$pkg")
done
if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    log INFO "installing runtime deps: ${missing_pkgs[*]}"
    apt-get update -qq && apt-get install -y -qq "${missing_pkgs[@]}" >> "$LOG_FILE" || { log ERROR "dependency install failed"; exit 1; }
fi

# ===== current version (fall back to parsing nginx -V when the marker is absent) =====
current_tag=""
if [[ -f "$MARKER" ]]; then
    current_tag=$(cat "$MARKER")
elif [[ -x "$NGINX_PREFIX/sbin/nginx" ]]; then
    info=$("$NGINX_PREFIX/sbin/nginx" -V 2>&1 || true)
    n_ver=$(echo "$info" | grep -oP 'nginx/\K[0-9.]+' 2>/dev/null || echo "")
    s_ver=$(echo "$info" | grep -oP 'OpenSSL \K[0-9.]+' 2>/dev/null || echo "")
    [[ -n "$n_ver" ]] && current_tag="nginx-$n_ver-openssl-${s_ver:-unknown}"
fi

# ===== fetch latest release =====
fetch_latest() {
    local data tag
    data=$(curl $CURL_OPTS "https://api.github.com/repos/$REPO/releases/latest") || { log ERROR "failed to fetch release"; exit 1; }
    tag=$(echo "$data" | jq -r '.tag_name // empty')
    [[ -z "$tag" ]] && { log ERROR "release has no tag"; exit 1; }
    [[ "$tag" =~ ^nginx-[0-9.]+-openssl-[0-9.]+$ ]] || { log ERROR "invalid tag: $tag"; exit 1; }
    echo "$tag"
}

latest_tag=$(fetch_latest)
log INFO "current: ${current_tag:-not installed} | latest: $latest_tag"

if [[ "$current_tag" == "$latest_tag" ]]; then
    log INFO "already up to date, nothing to do"
    exit 0
fi

latest_nginx=$(echo "$latest_tag" | sed -n 's/^nginx-\([0-9.]*\)-openssl.*/\1/p')
latest_ssl=$(echo "$latest_tag" | sed -n 's/.*-openssl-\([0-9.]*\)$/\1/p')

# ===== download + verify =====
cd "$WORK"
asset_url="https://github.com/$REPO/releases/download/$latest_tag/nginx-$latest_nginx-openssl-$latest_ssl.tar.gz"
log INFO "downloading: $asset_url"
curl $CURL_OPTS -o nginx.tar.gz "$asset_url" || { log ERROR "failed to download tarball"; exit 1; }
curl $CURL_OPTS -o nginx.tar.gz.sig "$asset_url.sig" || { log ERROR "failed to download signature"; exit 1; }

[[ -f "$KEYRING" ]] || { log ERROR "verification keyring missing: $KEYRING"; fatal "GPG keyring not configured"; }

verify() {
    # gpgv verifies the tarball signature (hard gate)
    if ! gpgv --keyring "$KEYRING" nginx.tar.gz.sig nginx.tar.gz; then
        fatal "gpgv signature verification failed"
    fi
    tar -tzf nginx.tar.gz >/dev/null || fatal "corrupt tarball"
    tar -xzf nginx.tar.gz -C .
    [[ -x ./sbin/nginx ]] || fatal "no nginx binary inside tarball"
}

verify

# runtime dependency check (ldd must not report anything not found)
if ldd ./sbin/nginx | grep -qi 'not found'; then
    ldd ./sbin/nginx
    fatal "missing runtime dependencies (ldd)"
fi

# ===== branch: fresh install / smooth upgrade =====
if [[ ! -x "$NGINX_PREFIX/sbin/nginx" ]]; then
    # ---- fresh VPS ----
    log INFO "fresh install nginx $latest_nginx (openssl $latest_ssl)"
    mkdir -p "$NGINX_PREFIX/sbin"
    cp -a ./sbin/nginx "$NGINX_PREFIX/sbin/nginx"
    chmod 755 "$NGINX_PREFIX/sbin/nginx"
    ln -sf "$NGINX_PREFIX/sbin/nginx" /usr/local/bin/nginx || true

    # only write a minimal placeholder config when none exists (never overwrite)
    if [[ ! -f /etc/nginx/nginx.conf ]]; then
        log INFO "writing placeholder nginx.conf"
        cat > /etc/nginx/nginx.conf << 'EOF'
# Minimal placeholder config (generated by the nginx auto-update script).
# Edit this to add your real server / SSL configuration.
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    sendfile on;
    client_body_temp_path /var/cache/nginx/client_temp;
    proxy_temp_path /var/cache/nginx/proxy_temp;
    fastcgi_temp_path /var/cache/nginx/fastcgi_temp;
    uwsgi_temp_path /var/cache/nginx/uwsgi_temp;
    scgi_temp_path /var/cache/nginx/scgi_temp;
    server {
        listen 80;
        server_name _;
        return 200 "ok\n";
    }
}
EOF
    fi

    svc="/etc/systemd/system/nginx.service"
    if [[ ! -f "$svc" ]]; then
        cat > "$svc" << 'EOF'
[Unit]
Description=Nginx HTTP Server
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/local/nginx/sbin/nginx -t -q
ExecStart=/usr/local/nginx/sbin/nginx
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        log INFO "created systemd service"
    fi

    systemctl enable nginx >/dev/null 2>&1 || true
    if ! "$NGINX_PREFIX/sbin/nginx" -t >/dev/null 2>&1; then
        log ERROR "nginx -t failed (placeholder config problem?)"
        fatal "config check failed"
    fi
    systemctl start nginx || { log ERROR "systemctl start nginx failed"; fatal "first start failed"; }
    echo "$latest_tag" > "$MARKER"
    log INFO "fresh install complete: $latest_tag"
else
    # ---- existing install: smooth upgrade ----
    log INFO "upgrading nginx to $latest_tag"
    nginx_was_running=0
    systemctl is-active --quiet nginx >/dev/null 2>&1 && nginx_was_running=1

    rollback_backup=""
    backup="$BACKUP_DIR/nginx-$(date +%Y%m%d-%H%M%S)"
    cp -a "$NGINX_PREFIX/sbin/nginx" "$backup"
    [[ $nginx_was_running -eq 1 ]] && { rollback_backup="$WORK/nginx-rollback.bin"; cp -a "$backup" "$rollback_backup"; } || true
    log INFO "backup: $(basename "$backup")${rollback_backup:+ (incl. rollback copy)}"

    # prune old backups
    count=$(ls -1 "$BACKUP_DIR"/nginx-* 2>/dev/null | wc -l || echo 0)
    [[ $count -gt $MAX_BACKUPS ]] && ls -1t "$BACKUP_DIR"/nginx-* 2>/dev/null | tail -n $((count - MAX_BACKUPS)) | xargs -r rm -f || true

    # install the new binary
    cp -a ./sbin/nginx "$NGINX_PREFIX/sbin/nginx"
    chmod 755 "$NGINX_PREFIX/sbin/nginx"

    # run -t with the new binary to validate config compatibility; roll back + trip breaker on failure
    if ! "$NGINX_PREFIX/sbin/nginx" -t >/dev/null 2>&1; then
        log ERROR "new binary nginx -t failed, rolling back"
        [[ -f "$rollback_backup" ]] && cp -a "$rollback_backup" "$NGINX_PREFIX/sbin/nginx" || true
        fatal "new binary nginx -t failed"
    fi

    if [[ $nginx_was_running -eq 1 ]]; then
        smooth_upgrade=0
        if [[ -f /run/nginx.pid ]]; then
            old_pid=$(cat /run/nginx.pid)
            kill -USR2 "$old_pid" 2>/dev/null && {
                for i in $(seq 1 20); do [[ -f /run/nginx.pid.oldbin ]] && break || sleep 0.5; done
                if [[ -f /run/nginx.pid.oldbin && -f /run/nginx.pid ]]; then
                    new_pid=$(cat /run/nginx.pid 2>/dev/null || echo "")
                    [[ -n "$new_pid" ]] && kill -0 "$new_pid" 2>/dev/null && sleep 3 && kill -0 "$new_pid" 2>/dev/null && {
                        kill -QUIT "$old_pid" 2>/dev/null || true
                        log INFO "smooth upgrade successful"
                        smooth_upgrade=1
                    }
                fi
            } || true
        fi
        [[ $smooth_upgrade -eq 0 ]] && {
            log WARN "smooth upgrade failed, trying restart"
            systemctl restart nginx 2>/dev/null || {
                log ERROR "restart failed, rolling back"
                [[ -f "$rollback_backup" ]] && cp -a "$rollback_backup" "$NGINX_PREFIX/sbin/nginx" && log INFO "old binary restored" || true
                systemctl start nginx 2>/dev/null || fatal "cannot start after rollback"
                fatal "upgrade failed, rolled back and recovered"
            }
            log INFO "restart upgrade successful"
            smooth_upgrade=1
        }
        sleep 2; systemctl is-active --quiet nginx || fatal "service unhealthy after upgrade"
    else
        log INFO "nginx not running, installing binary without starting"
    fi
    echo "$latest_tag" > "$MARKER"
    log INFO "upgrade complete: $latest_tag"
fi

log INFO "========== update complete =========="
log INFO "version: nginx $latest_nginx | openssl $latest_ssl"
echo "done: $latest_tag"
