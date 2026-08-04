#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Temporarily allow browser UI login over plain HTTP on an HA app node.
# Backs up the secure nginx conf, then strips Secure from WPORTALSESSION cookies.
#
# Default HA nginx keeps Secure cookies (correct behind the HTTPS load balancer).
# Run restore-http-ui-test.sh when finished testing.
#
# Run on the app-node host (uses docker exec into the mamori container).

set -euo pipefail

DOCKER="${DOCKER:-docker}"
CONTAINER_NAME="${CONTAINER_NAME:-mamori}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/conf.d/default.conf}"
BACKUP_DIR="${BACKUP_DIR:-/opt/mamori/http-ui-test-backup}"
HOST_BACKUP_DIR="${HOST_BACKUP_DIR:-/opt/mamori/http-ui-test-backup}"

usage() {
    cat <<'EOF'
Usage: enable-http-ui-test.sh [options]

Back up the node's secure nginx config, then apply HTTP UI test settings
(proxy_cookie_flags ... nosecure) so browsers can log in on http:// without an LB.

Options:
  -n, --name <container>   Mamori container name (default: mamori)
  -h, --help               Show this help

Restore with:
  bash restore-http-ui-test.sh
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)
            shift
            CONTAINER_NAME="${1:-}"
            [[ -n "$CONTAINER_NAME" ]] || { echo "Missing value for --name" >&2; exit 1; }
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

mkdir -p "$HOST_BACKUP_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
HOST_BACKUP_FILE="${HOST_BACKUP_DIR}/default.conf.secure.${TS}"
MARKER="${HOST_BACKUP_DIR}/ACTIVE_BACKUP"

echo "Backing up secure nginx config from ${CONTAINER_NAME}:${NGINX_CONF}"
$DOCKER cp "${CONTAINER_NAME}:${NGINX_CONF}" "$HOST_BACKUP_FILE"
printf '%s\n' "$HOST_BACKUP_FILE" > "$MARKER"
# Keep a stable "latest" pointer for restore
cp -f "$HOST_BACKUP_FILE" "${HOST_BACKUP_DIR}/default.conf.secure.latest"
echo "  saved: $HOST_BACKUP_FILE"

# Apply inside container: insert proxy_cookie_flags after x-forwarded-proto in location /
$DOCKER exec "$CONTAINER_NAME" bash -s <<'EOS'
set -euo pipefail
CONF=/etc/nginx/conf.d/default.conf
if grep -q 'proxy_cookie_flags WPORTALSESSION nosecure' "$CONF"; then
  echo "HTTP UI test cookie flags already present — no change"
  nginx -t
  exit 0
fi

python3 - <<'PY'
from pathlib import Path
p = Path("/etc/nginx/conf.d/default.conf")
t = p.read_text()
idx = t.find("location / {")
if idx < 0:
    raise SystemExit("location / { not found in nginx config")
# Prefer matching the HA cluster header pair; fall back to x-forwarded-proto alone
needles = [
    "proxy_set_header X-Force-HTTPS true;\n             proxy_set_header x-forwarded-proto https;",
    "proxy_set_header x-forwarded-proto https;",
]
insert_after = None
for n in needles:
    pos = t.find(n, idx)
    if pos >= 0:
        insert_after = (pos, n)
        break
if not insert_after:
    raise SystemExit("could not find x-forwarded-proto https in location /")
pos, n = insert_after
flag = (
    n
    + "\n             # TEMP: HTTP UI test — allow WPORTALSESSION without Secure (restore-http-ui-test.sh)"
    + "\n             proxy_cookie_flags WPORTALSESSION nosecure httponly samesite=strict;"
)
t = t[:pos] + flag + t[pos + len(n):]
p.write_text(t)
print("patched nginx for HTTP UI test")
PY

nginx -t
nginx -s reload
echo "nginx reloaded"
EOS

echo ""
echo "HTTP UI test mode ENABLED on ${CONTAINER_NAME}."
echo "  Backup marker: $MARKER"
echo "  Restore with:  bash restore-http-ui-test.sh"
echo "Verify: curl -sS -D- -o /dev/null http://127.0.0.1/ | grep -i set-cookie"
echo "  (should NOT include 'secure')"
