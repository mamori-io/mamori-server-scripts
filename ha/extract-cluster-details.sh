#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Extract shared-service connection details from an existing Mamori HA hub node.
# Run on the app-node host (reads the mamori-var Docker volume) or inside the
# mamori container. Writes a KEY=value env file for later HA join scripts.

set -euo pipefail

OUTPUT_FILE=""
DUMP_ALL=0
MAMORI_CONTAINER="${MAMORI_CONTAINER:-mamori}"
MAMORI_VAR_VOLUME="${MAMORI_VAR_VOLUME:-mamori-var}"

resolve_mamori_var() {
    # Prefer an explicit override.
    if [[ -n "${MAMORI_VAR:-}" ]]; then
        return 0
    fi

    # Inside the container (or host bind of the same path).
    if [[ -f /opt/mamori/var/derby.properties ]]; then
        MAMORI_VAR=/opt/mamori/var
        return 0
    fi

    # Host: named Docker volume used by `docker create ... -v mamori-var:/opt/mamori/var`
    if command -v docker >/dev/null 2>&1; then
        local mount
        mount="$(docker volume inspect -f '{{.Mountpoint}}' "$MAMORI_VAR_VOLUME" 2>/dev/null || true)"
        if [[ -n "$mount" && -f "$mount/derby.properties" ]]; then
            MAMORI_VAR="$mount"
            return 0
        fi

        # Fallback: inspect the running container mount
        mount="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/opt/mamori/var"}}{{.Source}}{{end}}{{end}}' "$MAMORI_CONTAINER" 2>/dev/null || true)"
        if [[ -n "$mount" && -f "$mount/derby.properties" ]]; then
            MAMORI_VAR="$mount"
            return 0
        fi
    fi

    # Common host volume path when docker root is default
    if [[ -f /var/lib/docker/volumes/${MAMORI_VAR_VOLUME}/_data/derby.properties ]]; then
        MAMORI_VAR="/var/lib/docker/volumes/${MAMORI_VAR_VOLUME}/_data"
        return 0
    fi

    return 1
}

usage() {
    cat <<'EOF'
Usage: extract-cluster-details.sh [options]

Extract Postgres, MQTT, Influx, encryption key, encrypted portal root
(`DERBY_USER_ROOT`), and related HA connection details from this Mamori hub
node into an env file.

Run from the host (recommended) or inside the mamori container. On the host
the script sets MAMORI_VAR from the mamori-var Docker volume automatically.

Options:
  -o, --output <file>   Output path (default: ./cluster-details.env)
  -a, --all             Also dump every rms.server_property row (sensitive)
  -h, --help            Show this help

Environment:
  MAMORI_VAR            Override path to Mamori var dir (contains derby.properties)
  DERBY_PROPS           Override path to derby.properties
  QUARTZ_PROPS          Override path to quartz.properties
  MAMORI_CONTAINER      Docker container name (default: mamori)
  MAMORI_VAR_VOLUME     Docker volume name (default: mamori-var)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            shift
            OUTPUT_FILE="${1:-}"
            [[ -n "$OUTPUT_FILE" ]] || { echo "Missing value for --output" >&2; exit 1; }
            ;;
        -a|--all)
            DUMP_ALL=1
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

if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="$(pwd)/cluster-details.env"
fi

if ! resolve_mamori_var; then
    echo "ERROR: could not locate Mamori var directory (derby.properties)." >&2
    echo "Set MAMORI_VAR or DERBY_PROPS, or ensure Docker volume '$MAMORI_VAR_VOLUME' exists." >&2
    exit 1
fi

DERBY_PROPS="${DERBY_PROPS:-$MAMORI_VAR/derby.properties}"
QUARTZ_PROPS="${QUARTZ_PROPS:-$MAMORI_VAR/quartz.properties}"

echo "Using MAMORI_VAR=$MAMORI_VAR"
echo "Using DERBY_PROPS=$DERBY_PROPS"

prop_get() {
    # prop_get <file> <key>
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2-
}

jdbc_host() {
    # jdbc:postgresql://HOST:PORT/DB
    sed -n 's|^jdbc:postgresql://\([^:/]*\).*|\1|p'
}

jdbc_port() {
    sed -n 's|^jdbc:postgresql://[^:]*:\([0-9]*\)/.*|\1|p'
}

jdbc_db() {
    sed -n 's|^jdbc:postgresql://[^/]*/\([^?]*\).*|\1|p'
}

escape_env() {
    # Escape for double-quoted shell assignment
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

emit() {
    local key="$1" val="${2-}"
    printf '%s="%s"\n' "$key" "$(escape_env "$val")"
}

if [[ ! -f "$DERBY_PROPS" ]]; then
    echo "ERROR: derby.properties not found at $DERBY_PROPS" >&2
    echo "Set MAMORI_VAR or DERBY_PROPS to the host volume path or container path." >&2
    exit 1
fi

RMS_URL="$(prop_get "$DERBY_PROPS" "mamori.rms.connectionUrl" || true)"
AUDIT_URL="$(prop_get "$DERBY_PROPS" "mamori.audit.connectionUrl" || true)"
PG_USER="$(prop_get "$DERBY_PROPS" "mamori.rms.user" || true)"
PG_PASSWORD="$(prop_get "$DERBY_PROPS" "mamori.rms.password" || true)"
ENCRYPT_KEY="$(prop_get "$DERBY_PROPS" "mamori.security.encrypt.key" || true)"
DERBY_USER_ROOT="$(prop_get "$DERBY_PROPS" "derby.user.root" || true)"
if [[ -n "$DERBY_USER_ROOT" && "$DERBY_USER_ROOT" == "REPLACEME" ]]; then
    DERBY_USER_ROOT=""
fi

if [[ -z "$RMS_URL" ]]; then
    echo "ERROR: mamori.rms.connectionUrl missing in $DERBY_PROPS" >&2
    exit 1
fi

PG_HOST="$(printf '%s' "$RMS_URL" | jdbc_host)"
PG_PORT="$(printf '%s' "$RMS_URL" | jdbc_port)"
PG_DB_SYS="$(printf '%s' "$RMS_URL" | jdbc_db)"
PG_DB_AUDIT="$(printf '%s' "$AUDIT_URL" | jdbc_db)"

PG_PORT="${PG_PORT:-5432}"
PG_DB_SYS="${PG_DB_SYS:-mamorisys}"
PG_DB_AUDIT="${PG_DB_AUDIT:-audit}"

# Cross-check quartz if present
if [[ -f "$QUARTZ_PROPS" ]]; then
    QZ_URL="$(prop_get "$QUARTZ_PROPS" "org.quartz.dataSource.qzDS.URL" || true)"
    if [[ -n "$QZ_URL" ]]; then
        QZ_HOST="$(printf '%s' "$QZ_URL" | jdbc_host)"
        if [[ -n "$QZ_HOST" && "$QZ_HOST" != "$PG_HOST" ]]; then
            echo "WARNING: quartz PG host ($QZ_HOST) differs from derby ($PG_HOST)" >&2
        fi
    fi
fi

if command -v psql >/dev/null 2>&1; then
    PSQL=(psql)
elif [[ -x /usr/bin/psql ]]; then
    PSQL=(/usr/bin/psql)
elif command -v docker >/dev/null 2>&1 && docker inspect "$MAMORI_CONTAINER" >/dev/null 2>&1; then
    # Host may not have client tools; use psql inside the mamori container.
    PSQL=(docker exec -e PGPASSWORD="$PG_PASSWORD" "$MAMORI_CONTAINER" psql)
else
    echo "ERROR: psql not found; install postgresql-client or ensure container '$MAMORI_CONTAINER' is running." >&2
    exit 1
fi

export PGPASSWORD="$PG_PASSWORD"

server_prop() {
    local key="$1"
    "${PSQL[@]}" -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB_SYS" -Atqc \
        "select value_property from rms.server_property where lower(key_property) = lower('$key') limit 1;" \
        2>/dev/null || true
}

MQTT_SERVER="$(server_prop mqtt_server)"
INFLUX_WRITE_URL="$(server_prop influxdb_write_url)"
HAPROXY="$(server_prop haproxy)"
WEB_URL="$(server_prop web_url)"
if [[ -z "$WEB_URL" ]]; then
    WEB_URL="$(server_prop 'web_server url')"
fi
MAMORI_SERVER_IP="$(server_prop mamori_server_ip)"
HTTP_PROXY_PUBLIC="$(server_prop http_proxy_public_address)"
WIREGUARD_PUBLIC="$(server_prop wireguard_public_address)"
WIREGUARD_DNS="$(server_prop wireguard_dns_server)"
INFLUX_LOG_BUCKET="$(server_prop influx_log_bucket)"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

{
    echo "# Generated by extract-cluster-details.sh on $(hostname) at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Connection details for joining / provisioning another HA app node."
    echo

    emit HOSTNAME "$(hostname 2>/dev/null || true)"
    emit PG_HOST "$PG_HOST"
    emit PG_PORT "$PG_PORT"
    emit PG_USER "$PG_USER"
    emit PG_PASSWORD "$PG_PASSWORD"
    emit PG_DB_SYS "$PG_DB_SYS"
    emit PG_DB_AUDIT "$PG_DB_AUDIT"
    emit JDBC_URL_SYS "$RMS_URL"
    emit JDBC_URL_AUDIT "$AUDIT_URL"
    emit MAMORI_ENCRYPTION_KEY "$ENCRYPT_KEY"
    emit DERBY_USER_ROOT "$DERBY_USER_ROOT"

    emit MQTT_SERVER "$MQTT_SERVER"
    emit INFLUXDB_WRITE_URL "$INFLUX_WRITE_URL"
    emit INFLUX_LOG_BUCKET "$INFLUX_LOG_BUCKET"
    emit HAPROXY "$HAPROXY"
    emit WEB_URL "$WEB_URL"
    emit MAMORI_SERVER_IP "$MAMORI_SERVER_IP"
    emit HTTP_PROXY_PUBLIC_ADDRESS "$HTTP_PROXY_PUBLIC"
    emit WIREGUARD_PUBLIC_ADDRESS "$WIREGUARD_PUBLIC"
    emit WIREGUARD_DNS_SERVER "$WIREGUARD_DNS"

    if [[ "$DUMP_ALL" -eq 1 ]]; then
        echo
        echo "# --- all rms.server_property (sensitive) ---"
        "${PSQL[@]}" -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB_SYS" -Atqc \
            "select key_property || '=' || coalesce(value_property, '') from rms.server_property order by key_property;" \
            2>/dev/null | while IFS= read -r line; do
                key="${line%%=*}"
                val="${line#*=}"
                # Prefix to avoid clobbering typed exports above
                safe_key="$(printf '%s' "$key" | tr '[:lower:]. -' '[:upper:]___' | tr -cd 'A-Z0-9_')"
                emit "SP_${safe_key}" "$val"
            done
    fi
} > "$TMP"

umask 077
mv "$TMP" "$OUTPUT_FILE"
trap - EXIT

echo "Wrote $OUTPUT_FILE"
echo "Summary:"
echo "  PG:      ${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB_SYS}"
echo "  MQTT:    ${MQTT_SERVER:-<unset>}"
echo "  Influx:  ${INFLUX_WRITE_URL:-<unset>}"
echo "  HAProxy: ${HAPROXY:-<unset>}"
echo "  Web URL: ${WEB_URL:-<unset>}"
