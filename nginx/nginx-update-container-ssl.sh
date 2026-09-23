#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Install TLS cert/key into the mamori container nginx SSL paths and restart the container.
# Run on a Mamori node host (outside Docker) when SSL is terminated in the mamori container,
# or when a UX certificate update failed to write /etc/nginx/ssl.
#
# Destinations (inside container):
#   /etc/nginx/ssl/nginx.crt
#   /etc/nginx/ssl/nginx.key
#
set -euo pipefail

DOCKER="${DOCKER:-sudo docker}"
CONTAINER="${CONTAINER:-mamori}"
RELOAD_ONLY=0
CRT=""
KEY=""

usage() {
  echo "Usage: $0 <cert.crt> <key.key> [--container NAME] [--reload]" >&2
  echo "  Run on the host (outside Docker). Requires a running or stopped mamori container." >&2
  echo "  Default: docker restart. Use --reload for 'sv reload nginx' only." >&2
  exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container|-c)
      CONTAINER="${2:?}"
      shift 2
      ;;
    --reload)
      RELOAD_ONLY=1
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

if ! $DOCKER inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "Error: docker container '$CONTAINER' not found." >&2
  exit 1
fi

DEST_CRT=/etc/nginx/ssl/nginx.crt
DEST_KEY=/etc/nginx/ssl/nginx.key

echo "Installing SSL cert/key into container '$CONTAINER'..."
$DOCKER exec "$CONTAINER" mkdir -p /etc/nginx/ssl
$DOCKER cp "$CRT" "${CONTAINER}:${DEST_CRT}"
$DOCKER cp "$KEY" "${CONTAINER}:${DEST_KEY}"
$DOCKER exec "$CONTAINER" chmod 644 "$DEST_CRT"
$DOCKER exec "$CONTAINER" chmod 600 "$DEST_KEY"

echo "Testing nginx config in container..."
$DOCKER exec "$CONTAINER" nginx -t

if [[ "$RELOAD_ONLY" -eq 1 ]]; then
  echo "Reloading nginx in container..."
  $DOCKER exec "$CONTAINER" sv reload nginx
else
  echo "Restarting container '$CONTAINER'..."
  $DOCKER restart "$CONTAINER"
fi

echo "Done."
echo "  ${CONTAINER}:${DEST_CRT}"
echo "  ${CONTAINER}:${DEST_KEY}"
