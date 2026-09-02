#!/bin/bash
# Version detection: fetch the latest upstream nginx stable + OpenSSL LTS and
# compare against versions.json (the last published version) to decide whether
# a build is needed. Called by CI before building.
#   exit 0 = upstream has newer releases (LATEST_NGINX / LATEST_SSL on stdout)
#   exit 1 = already up to date, no build needed
set -euo pipefail
readonly CURL_OPTS="--connect-timeout 10 --max-time 60 --retry 3 -fsSL"
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly VERSIONS_FILE="$ROOT/versions.json"

version_gt() {
    [[ -z "$1" || -z "$2" ]] && return 1
    [[ "$1" == "$2" ]] && return 1
    printf '%s\n%s\n' "$1" "$2" | sort -V -C && return 1 || return 0
}

# Latest upstream nginx stable (stable only: patch number is even)
latest_nginx() {
    curl $CURL_OPTS "https://nginx.org/en/download.html" \
        | grep -oP 'nginx-\K[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.gz)' \
        | grep -E '\.[0-9]*[02468]\.[0-9]+$' \
        | sort -V | tail -1 || true
}

# Latest upstream OpenSSL LTS (same logic as the legacy script)
latest_openssl() {
    local page lts
    page=$(curl $CURL_OPTS "https://www.openssl.org/source/" || echo "")
    lts=$(echo "$page" | grep -oP '\d+\.\d+(?= \[LTS\])' | paste -sd '|' || echo "")
    echo "$page" | grep -oP "openssl-(${lts:-})\.[0-9]+\.tar\.gz" \
        | sed 's/openssl-//' | sed 's/\.tar\.gz//' | sort -V | tail -1 || echo ""
}

[ ! -f "$VERSIONS_FILE" ] && { echo "versions.json not found" >&2; exit 1; }
published_nginx=$(jq -r '.nginx' "$VERSIONS_FILE")
published_ssl=$(jq -r '.openssl' "$VERSIONS_FILE")

latest_nginx_v=$(latest_nginx)
latest_ssl_v=$(latest_openssl)
[ -z "$latest_nginx_v" ] && { echo "could not fetch nginx version" >&2; exit 1; }
[ -z "$latest_ssl_v" ] && { echo "could not fetch OpenSSL version" >&2; exit 1; }

echo "published: nginx=$published_nginx openssl=$published_ssl"
echo "upstream:  nginx=$latest_nginx_v openssl=$latest_ssl_v"

need=1
if version_gt "$latest_nginx_v" "$published_nginx" || version_gt "$latest_ssl_v" "$published_ssl"; then
  need=0
fi

if [ "$need" -eq 0 ]; then
  echo "newer version available, build needed."
  echo "LATEST_NGINX=$latest_nginx_v"
  echo "LATEST_SSL=$latest_ssl_v"
  exit 0
fi

echo "already up to date, skipping build."
exit 1
