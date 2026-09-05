#!/bin/bash
set -euo pipefail

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
readonly WORK_ROOT="/var/lib/nginx-update"
readonly RUNTIME_PKGS="zlib1g libpcre2-8-0 libjemalloc2"
ALLOW_DOWNGRADE=0
for arg in "$@"; do [[ "$arg" == "--allow-downgrade" ]] && ALLOW_DOWNGRADE=1; done
readonly ALLOW_DOWNGRADE

[[ $EUID -ne 0 ]] && { echo "root required"; exit 1; }
for cmd in jq gpgv curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "required command missing: $cmd (apt install jq gpg gnupg2)"; exit 1; }
done

exec 200>/var/lock/nginx-update.lock
flock -n 200 || { echo "another instance is running"; exit 1; }

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

# Validate the private work tree before executing downloaded files from it.
install -d -m 0700 -o root -g root "$WORK_ROOT"
parent="$WORK_ROOT"
while [[ "$parent" != "/" && "$parent" != "." ]]; do
    parent=$(dirname "$parent")
    [[ -d "$parent" ]] || { echo "missing parent dir: $parent" >&2; exit 1; }
    mode=$(stat -c '%a' "$parent" 2>/dev/null || echo "?")
    owner=$(stat -c '%u' "$parent" 2>/dev/null || echo "?")
    if [[ ! "$mode" =~ ^[0-7]+$ ]] || (( (0$mode & 0022) != 0 )) || [[ "$owner" != "0" ]]; then
        echo "unsafe parent dir (owner=$owner mode=$mode): $parent" >&2; exit 1
    fi
done
WORK=$(mktemp -d "$WORK_ROOT/nginx-update.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if ! getent group "$NGINX_USER" >/dev/null 2>&1; then
    groupadd -r "$NGINX_USER"
    log INFO "created group: $NGINX_USER"
fi
if ! getent passwd "$NGINX_USER" >/dev/null 2>&1; then
    useradd -r -g "$NGINX_USER" -s /sbin/nologin -d /nonexistent "$NGINX_USER"
    log INFO "created user: $NGINX_USER"
fi

install -d -m 0755 /var/log/nginx /etc/nginx /run/lock
mkdir -p /var/cache/nginx/{client_temp,proxy_temp,fastcgi_temp,uwsgi_temp,scgi_temp}
chown -R "$NGINX_USER:$NGINX_USER" /var/cache/nginx

missing_pkgs=()
for pkg in $RUNTIME_PKGS; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing_pkgs+=("$pkg")
done
if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    log INFO "installing runtime deps: ${missing_pkgs[*]}"
    apt-get update -qq && apt-get install -y -qq "${missing_pkgs[@]}" >> "$LOG_FILE" || { log ERROR "dependency install failed"; exit 1; }
fi

# Resolve the installed version when the marker predates this script.
current_tag=""
if [[ -f "$MARKER" ]]; then
    current_tag=$(cat "$MARKER")
elif [[ -x "$NGINX_PREFIX/sbin/nginx" ]]; then
    if ! "$NGINX_PREFIX/sbin/nginx" -t >/dev/null 2>&1 || ! systemctl is-active --quiet nginx; then
        fatal "installation has no version marker and is not confirmed healthy; check $NGINX_PREFIX/sbin/nginx -t and systemctl status nginx, restore the service manually, then retry"
    fi
    info=$("$NGINX_PREFIX/sbin/nginx" -V 2>&1 || true)
    n_ver=$(echo "$info" | grep -oP 'nginx/\K[0-9.]+' 2>/dev/null || echo "")
    s_ver=$(echo "$info" | grep -oP 'OpenSSL \K[0-9.]+' 2>/dev/null || echo "")
    [[ -n "$n_ver" ]] && current_tag="nginx-$n_ver-openssl-${s_ver:-unknown}"
fi

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
    [[ -f "$MARKER" ]] || echo "$latest_tag" > "$MARKER"
    log INFO "already up to date, nothing to do"
    exit 0
fi

latest_nginx=$(echo "$latest_tag" | sed -n 's/^nginx-\([0-9.]*\)-openssl.*/\1/p')
latest_ssl=$(echo "$latest_tag" | sed -n 's/.*-openssl-\([0-9.]*\)$/\1/p')

if [[ -n "$current_tag" ]]; then
    cur_nginx=$(echo "$current_tag" | sed -n 's/^nginx-\([0-9.]*\)-openssl.*/\1/p')
    cur_ssl=$(echo "$current_tag" | sed -n 's/.*-openssl-\([0-9.]*\)$/\1/p')
    downgrade_nginx=0; downgrade_ssl=0
    [[ -n "$cur_nginx" && -n "$latest_nginx" && "$cur_nginx" != "$latest_nginx" ]] && printf '%s\n%s\n' "$latest_nginx" "$cur_nginx" | sort -V -C && downgrade_nginx=1 || true
    [[ -n "$cur_ssl" && -n "$latest_ssl" && "$cur_ssl" != "$latest_ssl" ]] && printf '%s\n%s\n' "$latest_ssl" "$cur_ssl" | sort -V -C && downgrade_ssl=1 || true
    if [[ $downgrade_nginx -eq 1 || $downgrade_ssl -eq 1 ]]; then
        if [[ $ALLOW_DOWNGRADE -eq 1 ]]; then
            log WARN "downgrade detected (nginx $cur_nginx->$latest_nginx ssl $cur_ssl->$latest_ssl) but --allow-downgrade given; proceeding"
        else
            log ERROR "downgrade refused (nginx $cur_nginx->$latest_nginx ssl $cur_ssl->$latest_ssl); use --allow-downgrade to force"
            exit 1
        fi
    fi
fi

cd "$WORK"
asset_url="https://github.com/$REPO/releases/download/$latest_tag/nginx-$latest_nginx-openssl-$latest_ssl.tar.gz"
log INFO "downloading: $asset_url"
curl $CURL_OPTS -o nginx.tar.gz "$asset_url" || { log ERROR "failed to download tarball"; exit 1; }
curl $CURL_OPTS -o nginx.tar.gz.sig "$asset_url.sig" || { log ERROR "failed to download signature"; exit 1; }

[[ -f "$KEYRING" ]] || { log ERROR "verification keyring missing: $KEYRING"; fatal "GPG keyring not configured"; }

verify() {
    if ! gpgv --keyring "$KEYRING" nginx.tar.gz.sig nginx.tar.gz; then
        fatal "gpgv signature verification failed"
    fi
    tar -tzf nginx.tar.gz >/dev/null || fatal "corrupt tarball"
    tar -xzf nginx.tar.gz -C .
    [[ -x ./sbin/nginx ]] || fatal "no nginx binary inside tarball"
    [[ -f ./conf/mime.types ]] || fatal "no conf/mime.types inside tarball"
}

verify

if ldd ./sbin/nginx | grep -qi 'not found'; then
    ldd ./sbin/nginx
    fatal "missing runtime dependencies (ldd)"
fi

if [[ ! -x "$NGINX_PREFIX/sbin/nginx" ]]; then
    log INFO "fresh install nginx $latest_nginx (openssl $latest_ssl)"
    install -d -m 0755 "$NGINX_PREFIX/sbin"
    tmp="$NGINX_PREFIX/sbin/nginx.new"
    install -m 0755 ./sbin/nginx "$tmp"
    mv -f "$tmp" "$NGINX_PREFIX/sbin/nginx"
    ln -sf "$NGINX_PREFIX/sbin/nginx" /usr/local/bin/nginx || true

    if [[ ! -f /etc/nginx/mime.types ]]; then
        log INFO "writing mime.types from release"
        install -m 0644 ./conf/mime.types /etc/nginx/mime.types
    fi

    if [[ ! -f /etc/nginx/nginx.conf ]]; then
        log INFO "writing placeholder nginx.conf"
        cat > /etc/nginx/nginx.conf << 'EOF'
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
    log INFO "upgrading nginx to $latest_tag"
    nginx_was_running=0
    systemctl is-active --quiet nginx >/dev/null 2>&1 && nginx_was_running=1

    backup="$BACKUP_DIR/nginx-$(date +%Y%m%d-%H%M%S)"
    cp -a "$NGINX_PREFIX/sbin/nginx" "$backup"
    rollback_backup="$WORK/nginx-rollback.bin"
    cp -a "$backup" "$rollback_backup"
    log INFO "backup: $(basename "$backup") (rollback copy ready)"

    count=$(ls -1 "$BACKUP_DIR"/nginx-* 2>/dev/null | wc -l || echo 0)
    [[ $count -gt $MAX_BACKUPS ]] && ls -1t "$BACKUP_DIR"/nginx-* 2>/dev/null | tail -n $((count - MAX_BACKUPS)) | xargs -r rm -f || true

    standby="$NGINX_PREFIX/sbin/nginx.new"
    install -m 0755 ./sbin/nginx "$standby"

    if ! "$standby" -t >/dev/null 2>&1; then
        log ERROR "staged binary nginx -t failed, aborting without touching live nginx"
        rm -f "$standby"
        fatal "staged binary config check failed"
    fi

    if [[ $nginx_was_running -eq 1 ]]; then
        old_pid=$(cat /run/nginx.pid 2>/dev/null || true)
        if [[ ! "$old_pid" =~ ^[1-9][0-9]*$ || "$old_pid" == "1" ]] || ! kill -0 "$old_pid" 2>/dev/null; then
            fatal "missing or invalid live master PID in /run/nginx.pid; check systemctl status nginx"
        fi
        [[ ! -e /run/nginx.pid.oldbin ]] || fatal "previous upgrade has an .oldbin PID file; inspect nginx processes before retrying"

        # USR2 re-executes the binary at its installed path.
        mv -f "$standby" "$NGINX_PREFIX/sbin/nginx"
        smooth_upgrade=0
        new_pid=""
        if kill -USR2 "$old_pid" 2>/dev/null; then
            for i in $(seq 1 20); do
                if [[ -f /run/nginx.pid.oldbin && -f /run/nginx.pid ]]; then
                    new_pid=$(cat /run/nginx.pid 2>/dev/null || true)
                    if [[ "$new_pid" =~ ^[1-9][0-9]*$ && "$new_pid" != "1" && "$new_pid" != "$old_pid" ]] && kill -0 "$new_pid" 2>/dev/null; then
                        sleep 3
                        if kill -0 "$new_pid" 2>/dev/null && kill -QUIT "$old_pid" 2>/dev/null; then
                            smooth_upgrade=1
                        fi
                        break
                    fi
                fi
                sleep 0.5
            done
        fi
        if [[ $smooth_upgrade -eq 1 ]]; then
            sleep 2
            if ! systemctl is-active --quiet nginx; then
                smooth_upgrade=0
            fi
        fi
        if [[ $smooth_upgrade -eq 0 ]]; then
            log WARN "smooth upgrade did not confirm; restoring pre-upgrade binary"
            # Rename a separate inode over the executable, which may still be running.
            if ! cp -a "$rollback_backup" "$standby" || ! mv -f "$standby" "$NGINX_PREFIX/sbin/nginx"; then
                fatal "could not restore pre-upgrade binary; existing processes left running"
            fi
            if ! systemctl restart nginx; then
                fatal "could not restart nginx after restoring pre-upgrade binary"
            fi
            sleep 2
            if ! systemctl is-active --quiet nginx; then
                fatal "service unhealthy after restoring pre-upgrade binary"
            fi
            log INFO "pre-upgrade master restored via restart"
            fatal "upgrade failed; restored pre-upgrade master (see log)"
        fi
        log INFO "smooth upgrade successful"
    else
        log INFO "nginx not running, swapping binary without starting"
        mv -f "$standby" "$NGINX_PREFIX/sbin/nginx"
    fi
    echo "$latest_tag" > "$MARKER"
    log INFO "upgrade complete: $latest_tag"
fi

log INFO "========== update complete =========="
log INFO "version: nginx $latest_nginx | openssl $latest_ssl"
echo "done: $latest_tag"
