#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Refresh nginx configuration from files shipped inside the running container.
# Sources (inside container):
#   /opt/mamori/config/nginx-backup/nginx.conf -> /etc/nginx/nginx.conf
#   /opt/mamori/config/nginx-backup/mamori.conf | mamori-ipv4-only.conf -> conf.d/default.conf
#   /opt/mamori/config/nginx/*.conf -> /etc/nginx/mamori/
# Preserves /etc/nginx/ssl unless --regenerate-ssl.
#
# Must use: docker exec -i ... bash -s <<'EOF' so stdin reaches the container when run from the host.
#
set -euo pipefail

DOCKER="${DOCKER:-sudo docker}"
CONTAINER="${CONTAINER:-mamori}"
REGENERATE_SSL=0

usage() {
  echo "Usage: $0 [--container NAME] [--regenerate-ssl]" >&2
  echo "  Run on the host (outside Docker). Requires a running container." >&2
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container|-c)
      CONTAINER="${2:?}"
      shift 2
      ;;
    --regenerate-ssl)
      REGENERATE_SSL=1
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage 1
      ;;
  esac
done

if ! $DOCKER exec "$CONTAINER" test -d /opt/mamori/config/nginx-backup; then
  echo "Error: container '$CONTAINER' is not running or missing /opt/mamori/config/nginx-backup." >&2
  exit 1
fi

# -i is required: without it, stdin from the heredoc is not attached and bash -s runs nothing (exit 0).
if ! $DOCKER exec -i "$CONTAINER" bash -s -- "$REGENERATE_SSL" <<'EOF'
set -euo pipefail
REGENERATE_SSL="$1"

BACKUP_DIR="/opt/mamori/var/backups"
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_DIR" /etc/nginx/mamori /etc/nginx/conf.d

echo "Backing up current /etc/nginx (excluding ssl/) to ${BACKUP_DIR}/nginx-conf-${STAMP}.tgz ..."
if ! tar czf "${BACKUP_DIR}/nginx-conf-${STAMP}.tgz" -C /etc/nginx --exclude='ssl' . 2>/dev/null; then
  echo "Warning: backup tar had issues; continuing."
fi

if [[ "$REGENERATE_SSL" == "1" ]]; then
  echo "WARNING: Regenerating TLS under /etc/nginx/ssl (replacing existing certs)."
  mkdir -p /etc/nginx/ssl
  openssl genrsa -out /etc/nginx/ssl/nginx.key 2048
  openssl req -new -x509 -key /etc/nginx/ssl/nginx.key -out /etc/nginx/ssl/nginx.crt -days 3650 -subj /CN=local.mamori.io
fi

echo "Installing nginx.conf from image (/opt/mamori/config/nginx-backup/nginx.conf)..."
cp -v /opt/mamori/config/nginx-backup/nginx.conf /etc/nginx/nginx.conf

echo "Choosing default server config (IPv6 vs IPv4-only)..."
if ping6 -c 1 ::1 >/dev/null 2>&1; then
  echo "  IPv6 available: using mamori.conf"
  cp -v /opt/mamori/config/nginx-backup/mamori.conf /etc/nginx/conf.d/default.conf
else
  echo "  IPv6 not available: using mamori-ipv4-only.conf"
  cp -v /opt/mamori/config/nginx-backup/mamori-ipv4-only.conf /etc/nginx/conf.d/default.conf
fi

echo "Updating /etc/nginx/mamori/*.conf from image..."
shopt -s nullglob
for file in /opt/mamori/config/nginx/*.conf; do
  base=$(basename "$file")
  cp -v "$file" "/etc/nginx/mamori/$base"
done
shopt -u nullglob

echo "Testing nginx configuration..."
nginx -t

echo "Reloading nginx..."
nginx -s reload
echo "Done."
EOF
then
  echo "Error: update failed inside container (see messages above)." >&2
  exit 1
fi

