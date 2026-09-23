#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Install TLS cert/key for gateway / load-balancer nginx SSL termination and reload nginx.
# Run on the HA gateway host (not on m1/m2 app nodes) when the web UI terminates TLS on the gateway.
#
# Host defaults (auto-detect):
#   Prefer /etc/nginx/ssl/server.{crt,key} when present (sandbox HA gateway)
#   Otherwise /etc/nginx/ssl/nginx.{crt,key}
#
# Optional docker nginx LB:
#   --docker NAME installs into that container at /etc/nginx/ssl/nginx.{crt,key}
#
set -euo pipefail

DOCKER="${DOCKER:-sudo docker}"
CRT=""
KEY=""
DEST_CRT=""
DEST_KEY=""
DOCKER_NGINX=""
RESTART=0

usage() {
  echo "Usage: $0 <cert.crt> <key.key> [options]" >&2
  echo "  Run on the gateway / load-balancer host." >&2
  echo "Options:" >&2
  echo "  --dest-crt PATH   Destination cert path (default: auto-detect)" >&2
  echo "  --dest-key PATH   Destination key path (default: auto-detect)" >&2
  echo "  --docker NAME     Install into a docker nginx container instead of host paths" >&2
  echo "  --restart         Restart nginx/container instead of reload" >&2
  exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest-crt)
      DEST_CRT="${2:?}"
      shift 2
      ;;
    --dest-key)
      DEST_KEY="${2:?}"
      shift 2
      ;;
    --docker)
      DOCKER_NGINX="${2:?}"
      shift 2
      ;;
    --restart)
      RESTART=1
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage 1
      ;;
    *)
      if [[ -z "$CRT" ]]; then
        CRT=$1
      elif [[ -z "$KEY" ]]; then
        KEY=$1
      else
        echo "Unexpected argument: $1" >&2
        usage 1
      fi
      shift
      ;;
  esac
done

[[ -n "$CRT" && -n "$KEY" ]] || usage 1
[[ -f "$CRT" ]] || { echo "Certificate file not found: $CRT" >&2; exit 1; }
[[ -f "$KEY" ]] || { echo "Key file not found: $KEY" >&2; exit 1; }

detect_host_paths() {
  if [[ -f /etc/nginx/ssl/server.crt || -f /etc/nginx/ssl/server.key ]]; then
    DEST_CRT=${DEST_CRT:-/etc/nginx/ssl/server.crt}
    DEST_KEY=${DEST_KEY:-/etc/nginx/ssl/server.key}
  else
    DEST_CRT=${DEST_CRT:-/etc/nginx/ssl/nginx.crt}
    DEST_KEY=${DEST_KEY:-/etc/nginx/ssl/nginx.key}
  fi
}

if [[ -n "$DOCKER_NGINX" ]]; then
  if ! $DOCKER inspect "$DOCKER_NGINX" >/dev/null 2>&1; then
    echo "Error: docker container '$DOCKER_NGINX' not found." >&2
    exit 1
  fi
  DEST_CRT=${DEST_CRT:-/etc/nginx/ssl/nginx.crt}
  DEST_KEY=${DEST_KEY:-/etc/nginx/ssl/nginx.key}

  echo "Installing SSL cert/key into docker nginx '$DOCKER_NGINX'..."
  $DOCKER exec "$DOCKER_NGINX" mkdir -p /etc/nginx/ssl
  $DOCKER cp "$CRT" "${DOCKER_NGINX}:${DEST_CRT}"
  $DOCKER cp "$KEY" "${DOCKER_NGINX}:${DEST_KEY}"
  $DOCKER exec "$DOCKER_NGINX" chmod 644 "$DEST_CRT"
  $DOCKER exec "$DOCKER_NGINX" chmod 600 "$DEST_KEY"
  $DOCKER exec "$DOCKER_NGINX" nginx -t

  if [[ "$RESTART" -eq 1 ]]; then
    echo "Restarting container '$DOCKER_NGINX'..."
    $DOCKER restart "$DOCKER_NGINX"
  else
    echo "Reloading nginx in container..."
    $DOCKER exec "$DOCKER_NGINX" nginx -s reload || $DOCKER restart "$DOCKER_NGINX"
  fi

  echo "Done."
  echo "  ${DOCKER_NGINX}:${DEST_CRT}"
  echo "  ${DOCKER_NGINX}:${DEST_KEY}"
  exit 0
fi

detect_host_paths
mkdir -p "$(dirname "$DEST_CRT")"

echo "Installing SSL cert/key on gateway host nginx..."
install -m 644 "$CRT" "$DEST_CRT"
install -m 600 "$KEY" "$DEST_KEY"

echo "Testing nginx config..."
nginx -t

if [[ "$RESTART" -eq 1 ]]; then
  echo "Restarting nginx..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart nginx
  else
    service nginx restart
  fi
else
  echo "Reloading nginx..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload nginx
  else
    service nginx reload
  fi
fi

echo "Done."
echo "  $DEST_CRT"
echo "  $DEST_KEY"
