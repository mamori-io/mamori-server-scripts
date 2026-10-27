#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Repair a Grafana 13 clean install that crash-loops with:
#   missing configuration for current encryption provider misconfigured
#
# DM rewrites conf/defaults.ini on startup from an older template that has no
# [secrets_manager] section. Overrides go in conf/custom.ini, which DM does
# not replace. Leaked gpx_* plugin processes are killed so the container can
# fork again after hitting its task limit.
#
# Usage (on the Mamori host):
#   sudo ./fix_grafana_13.sh
#   MAMORI_CONTAINER=mamori sudo ./fix_grafana_13.sh
#

set -euo pipefail

DOCKER="${DOCKER:-sudo docker}"
CONTAINER="${MAMORI_CONTAINER:-mamori}"
GRAFANA_LOG="/opt/mamori/grafana/data/log/grafana.log"
WAIT_SECS="${GRAFANA_WAIT_SECS:-90}"

usage() {
    cat <<'EOF'
Usage: fix_grafana_13.sh

Stop Grafana in the Mamori container, write Grafana 13 encryption settings
to conf/custom.ini (keeping the existing secret_key), kill leaked plugin
processes, restart Grafana, and print a log check.

  MAMORI_CONTAINER   container name (default: mamori)
  DOCKER             docker command (default: sudo docker)
  GRAFANA_WAIT_SECS  seconds to wait for HTTP Server Listen (default: 90)

EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

run_priv() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

if ! $DOCKER inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "Container '${CONTAINER}' not found." >&2
    exit 1
fi

kill_leaked_plugins() {
    local init_pid pid args parent hops
    init_pid="$($DOCKER inspect -f '{{.State.Pid}}' "$CONTAINER")"
    if [[ -z "$init_pid" || "$init_pid" == "0" ]]; then
        echo "Container '${CONTAINER}' is not running." >&2
        exit 1
    fi
    while read -r pid args; do
        [[ -z "$pid" ]] && continue
        case "$args" in
            /opt/mamori/grafana/data/plugins-bundled/*) ;;
            *) continue ;;
        esac
        parent="$pid"
        hops=0
        while [[ "$parent" -gt 1 && "$hops" -lt 40 ]]; do
            if [[ "$parent" == "$init_pid" ]]; then
                run_priv kill "$pid" 2>/dev/null || true
                break
            fi
            parent="$(awk '/^PPid:/ {print $2}' "/proc/${parent}/status" 2>/dev/null || echo 0)"
            hops=$((hops + 1))
        done
    done < <(ps -ww -eo pid=,args=)
}

echo "Stopping Grafana in ${CONTAINER} ..."
if ! $DOCKER exec "$CONTAINER" sv stop grafana; then
    echo "sv stop failed (the container may be out of process slots). Killing leaked plugin processes ..."
    kill_leaked_plugins
    sleep 1
    $DOCKER exec "$CONTAINER" sv stop grafana
fi

echo "Killing leftover Grafana plugin processes ..."
kill_leaked_plugins
sleep 1

echo "Writing Grafana 13 settings to conf/custom.ini ..."
$DOCKER exec -i "$CONTAINER" bash -s <<'EOF'
set -euo pipefail
GRAFANA_HOME=/opt/mamori/grafana
DEFAULTS="$GRAFANA_HOME/conf/defaults.ini"
CUSTOM="$GRAFANA_HOME/conf/custom.ini"

read_security_secret() {
    awk '
        /^\[security\]/ { s = 1; next }
        /^\[/ { s = 0 }
        s && /^secret_key[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            print
            exit
        }
    ' "$1"
}

SECRET=""
if [[ -f "$DEFAULTS" ]]; then
    SECRET="$(read_security_secret "$DEFAULTS" || true)"
fi
if [[ -z "$SECRET" && -f "$CUSTOM" ]]; then
    SECRET="$(awk '
        /^\[secrets_manager\.encryption\.secret_key\.v1\]/ { s = 1; next }
        /^\[/ { s = 0 }
        s && /^secret_key[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            print
            exit
        }
    ' "$CUSTOM" || true)"
fi
if [[ -z "$SECRET" && -f "$CUSTOM" ]]; then
    SECRET="$(read_security_secret "$CUSTOM" || true)"
fi
if [[ -z "${SECRET// }" ]]; then
    echo "ERROR: no secret_key in ${DEFAULTS} or ${CUSTOM}. Refusing to invent one." >&2
    exit 1
fi

mkdir -p "$GRAFANA_HOME/conf"
touch "$CUSTOM"
if ! grep -q '^\[secrets_manager\]' "$CUSTOM"; then
    printf '\n[secrets_manager]\nencryption_provider = secret_key.v1\n' >> "$CUSTOM"
fi
if ! grep -q '^\[secrets_manager.encryption.secret_key.v1\]' "$CUSTOM"; then
    printf '\n[secrets_manager.encryption.secret_key.v1]\nsecret_key = %s\n' "$SECRET" >> "$CUSTOM"
fi
if ! grep -q '^\[unified_alerting.state_history\]' "$CUSTOM"; then
    printf '\n[unified_alerting.state_history]\nbackend = annotations\n' >> "$CUSTOM"
fi
echo "custom.ini updated"
EOF

log_bytes() {
    $DOCKER exec "$CONTAINER" stat -c %s "$GRAFANA_LOG" 2>/dev/null || echo 0
}

latest_start() {
    $DOCKER exec "$CONTAINER" awk '
        BEGIN { p = 0 }
        /Starting Grafana/ { buf = $0; p = 1; next }
        p { buf = buf ORS $0 }
        END { print buf }
    ' "$GRAFANA_LOG" 2>/dev/null || true
}

BEFORE="$(log_bytes)"
echo "Starting Grafana ..."
if ! $DOCKER exec "$CONTAINER" sv start grafana; then
    echo "sv start grafana returned an error; checking the log anyway ..." >&2
fi

deadline=$((SECONDS + WAIT_SECS))
result="timeout"
section=""
while [[ "$SECONDS" -lt "$deadline" ]]; do
    now="$(log_bytes)"
    if [[ "$now" -gt "$BEFORE" ]]; then
        fresh="$($DOCKER exec "$CONTAINER" tail -c +$((BEFORE + 1)) "$GRAFANA_LOG" 2>/dev/null || true)"
        if printf '%s\n' "$fresh" | grep -q 'Starting Grafana'; then
            section="$(latest_start)"
            if printf '%s\n' "$section" | grep -q 'missing configuration for current encryption provider\|fatal error: newosproc'; then
                result="error"
                break
            fi
            if printf '%s\n' "$section" | grep -q 'HTTP Server Listen'; then
                result="ok"
                break
            fi
        fi
    fi
    sleep 2
done

echo
echo "Check the latest Grafana start (older crash-loop lines are not the current start):"
echo
cat <<EOF
$DOCKER exec $CONTAINER awk 'BEGIN{p=0} /Starting Grafana/{buf=\$0; p=1; next} p{buf=buf ORS \$0} END{print buf}' $GRAFANA_LOG
EOF
echo

case "$result" in
    ok)
        echo "Grafana is up. The latest start logged HTTP Server Listen and did not log the encryption or newosproc errors."
        exit 0
        ;;
    error)
        echo "Grafana failed again. The latest start still contains the encryption provider error or fatal error: newosproc." >&2
        exit 1
        ;;
    *)
        echo "Timed out after ${WAIT_SECS}s waiting for HTTP Server Listen on the latest start." >&2
        exit 1
        ;;
esac
