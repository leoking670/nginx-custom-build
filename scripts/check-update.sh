#!/bin/bash
#   exit 0 = upstream has newer releases (LATEST_NGINX / LATEST_SSL on stdout)
#   exit 1 = already up to date, no build needed
#   exit 2 = version detection failed
set -euo pipefail
readonly CURL_OPTS="--connect-timeout 10 --max-time 60 --retry 3 -fsSL"
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly VERSIONS_FILE="$ROOT/versions.json"

version_gt() {
    [[ -z "$1" || -z "$2" ]] && return 1
    [[ "$1" == "$2" ]] && return 1
    printf '%s\n%s\n' "$1" "$2" | sort -V -C && return 1 || return 0
}

latest_nginx() {
    curl $CURL_OPTS "https://nginx.org/en/download.html" \
        | grep -oP 'nginx-\K[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.gz)' \
        | grep -E '\.[0-9]*[02468]\.[0-9]+$' \
        | sort -V | tail -1 || true
}

latest_openssl() {
    local page lts
    page=$(curl $CURL_OPTS "https://www.openssl.org/source/" || echo "")
    lts=$(echo "$page" | grep -oP '\d+\.\d+(?= \[LTS\])' | paste -sd '|' || echo "")
    echo "$page" | grep -oP "openssl-(${lts:-})\.[0-9]+\.tar\.gz" \
        | sed 's/openssl-//' | sed 's/\.tar\.gz//' | sort -V | tail -1 || echo ""
}

[ ! -f "$VERSIONS_FILE" ] && { echo "versions.json not found" >&2; exit 2; }
published_nginx=$(jq -er '.nginx | select(type == "string")' "$VERSIONS_FILE") || { echo "could not read nginx version from versions.json" >&2; exit 2; }
published_ssl=$(jq -er '.openssl | select(type == "string")' "$VERSIONS_FILE") || { echo "could not read OpenSSL version from versions.json" >&2; exit 2; }
if [[ ! "$published_nginx" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$published_ssl" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "invalid version in versions.json (expected three numeric components)" >&2
    exit 2
fi

latest_nginx_v=$(latest_nginx)
latest_ssl_v=$(latest_openssl)
[ -z "$latest_nginx_v" ] && { echo "could not fetch nginx version" >&2; exit 2; }
[ -z "$latest_ssl_v" ] && { echo "could not fetch OpenSSL version" >&2; exit 2; }

echo "published: nginx=$published_nginx openssl=$published_ssl"
echo "upstream:  nginx=$latest_nginx_v openssl=$latest_ssl_v"

if version_gt "$latest_nginx_v" "$published_nginx" || version_gt "$latest_ssl_v" "$published_ssl"; then
  echo "newer version available, build needed."
  echo "LATEST_NGINX=$latest_nginx_v"
  echo "LATEST_SSL=$latest_ssl_v"
  exit 0
fi

echo "already up to date, skipping build."
exit 1
