#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Restore the secure nginx config after enable-http-ui-test.sh.
# Run on the app-node host.

set -euo pipefail

DOCKER="${DOCKER:-docker}"
CONTAINER_NAME="${CONTAINER_NAME:-mamori}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/conf.d/default.conf}"
HOST_BACKUP_DIR="${HOST_BACKUP_DIR:-/opt/mamori/http-ui-test-backup}"

usage() {
    cat <<'EOF'
Usage: restore-http-ui-test.sh [options]

Restore the backed-up secure nginx config and reload nginx.

Options:
  -n, --name <container>   Mamori container name (default: mamori)
  -f, --file <path>        Specific backup file (default: ACTIVE_BACKUP or latest)
  -h, --help               Show this help
EOF
}

BACKUP_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)
            shift
            CONTAINER_NAME="${1:-}"
            [[ -n "$CONTAINER_NAME" ]] || { echo "Missing value for --name" >&2; exit 1; }
            ;;
        -f|--file)
            shift
            BACKUP_FILE="${1:-}"
            [[ -n "$BACKUP_FILE" ]] || { echo "Missing value for --file" >&2; exit 1; }
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if ! $DOCKER inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "ERROR: container '$CONTAINER_NAME' not found" >&2
    exit 1
fi

if [[ -z "$BACKUP_FILE" ]]; then
    MARKER="${HOST_BACKUP_DIR}/ACTIVE_BACKUP"
    LATEST="${HOST_BACKUP_DIR}/default.conf.secure.latest"
    if [[ -f "$MARKER" ]]; then
        BACKUP_FILE="$(tr -d '[:space:]' < "$MARKER")"
    elif [[ -f "$LATEST" ]]; then
        BACKUP_FILE="$LATEST"
    else
        echo "ERROR: no backup found under $HOST_BACKUP_DIR" >&2
        echo "Run enable-http-ui-test.sh first, or pass --file /path/to/backup" >&2
        exit 1
    fi
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "ERROR: backup file not found: $BACKUP_FILE" >&2
    exit 1
fi

echo "Restoring secure nginx config to ${CONTAINER_NAME}:${NGINX_CONF}"
echo "  from: $BACKUP_FILE"
$DOCKER cp "$BACKUP_FILE" "${CONTAINER_NAME}:${NGINX_CONF}"

$DOCKER exec "$CONTAINER_NAME" bash -c '
set -euo pipefail
nginx -t
if command -v sv >/dev/null 2>&1 && { [[ -d /etc/service/nginx ]] || [[ -d /etc/sv/nginx ]]; }; then
  sv restart nginx
  echo "nginx restarted via sv"
else
  nginx -s reload
  echo "nginx reloaded"
fi
'

rm -f "${HOST_BACKUP_DIR}/ACTIVE_BACKUP"

echo ""
echo "HTTP UI test mode DISABLED — secure nginx config restored."
echo "Verify: curl -sS -D- -o /dev/null http://127.0.0.1/ | grep -i set-cookie"
echo "  (should include 'secure')"
