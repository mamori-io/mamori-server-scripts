#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Repair / validate Grafana 13 in the Mamori AIO container.
#
# Grafana 13 needs the packaged conf/defaults.ini (secrets_manager, alerting,
# GMS). Mamori overlays belong in conf/custom.ini. Nginx must 301 exact
# /monitor to /monitor/ or Phoenix returns "Invalid URL".
#
# Usage (on the Mamori host):
#   sudo ./fix_grafana_13.sh
#   sudo ./fix_grafana_13.sh --validate
#   MAMORI_CONTAINER=mamori sudo ./fix_grafana_13.sh --validate
#

set -euo pipefail

DOCKER="${DOCKER:-sudo docker}"
CONTAINER="${MAMORI_CONTAINER:-mamori}"
GRAFANA_HOME="/opt/mamori/grafana"
GRAFANA_LOG="${GRAFANA_HOME}/data/log/grafana.log"
WAIT_SECS="${GRAFANA_WAIT_SECS:-90}"
VALIDATE_ONLY=0
GPX_MAX="${GRAFANA_GPX_MAX:-40}"

usage() {
    cat <<'EOF'
Usage: fix_grafana_13.sh [--validate]

  (default)  Stop Grafana, write Grafana 13 settings to conf/custom.ini,
             restore packaged defaults.ini if needed, fix nginx /monitor,
             kill leaked plugin processes, restart Grafana, then --validate.

  --validate Check the settings required for Grafana 13 + the Monitor menu.
             Does not change files. Exit 0 only if every check passes.

  MAMORI_CONTAINER   container name (default: mamori)
  DOCKER             docker command (default: sudo docker)
  GRAFANA_WAIT_SECS  seconds to wait for HTTP Server Listen (default: 90)

EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --validate|-validate|validate)
            VALIDATE_ONLY=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

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

ini_get() {
    local file="$1" section="$2" key="$3"
    $DOCKER exec "$CONTAINER" awk -v sec="[$section]" -v key="$key" '
        $0 == sec { insec=1; next }
        /^\[/ { insec=0 }
        insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/[[:space:]]+$/, "")
            print
            exit
        }
    ' "$file" 2>/dev/null || true
}

norm() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

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

count_gpx() {
    local init_pid pid args parent hops n=0
    init_pid="$($DOCKER inspect -f '{{.State.Pid}}' "$CONTAINER" 2>/dev/null || echo 0)"
    [[ -z "$init_pid" || "$init_pid" == "0" ]] && { echo 0; return; }
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
                n=$((n + 1))
                break
            fi
            parent="$(awk '/^PPid:/ {print $2}' "/proc/${parent}/status" 2>/dev/null || echo 0)"
            hops=$((hops + 1))
        done
    done < <(ps -ww -eo pid=,args=)
    echo "$n"
}

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

apply_custom_ini() {
    $DOCKER exec -i "$CONTAINER" bash -s <<'EOF'
set -euo pipefail
GRAFANA_HOME=/opt/mamori/grafana
DEFAULTS="$GRAFANA_HOME/conf/defaults.ini"
CUSTOM="$GRAFANA_HOME/conf/custom.ini"

ini_set() {
    _file="$1"
    _sec="$2"
    _key="$3"
    _val="$4"
    _tmp=$(mktemp)
    awk -v sec="[$_sec]" -v key="$_key" -v val="$_val" '
        function emit() { print key " = " val }
        BEGIN { done=0; insec=0 }
        $0 == sec { print; insec=1; next }
        insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { emit(); done=1; next }
        insec && /^\[/ { if (!done) emit(); done=1; insec=0 }
        { print }
        END {
            if (insec && !done) emit()
            else if (!done) { print ""; print sec; emit() }
        }
    ' "$_file" > "$_tmp" && mv "$_tmp" "$_file"
}

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
ini_set "$CUSTOM" "secrets_manager" "encryption_provider" "secret_key.v1"
ini_set "$CUSTOM" "secrets_manager.encryption.secret_key.v1" "secret_key" "$SECRET"
ini_set "$CUSTOM" "unified_alerting.state_history" "enabled" "true"
ini_set "$CUSTOM" "unified_alerting.state_history" "backend" "annotations"
ini_set "$CUSTOM" "unified_alerting.notification_history" "enabled" "false"
ini_set "$CUSTOM" "cloud_migration" "enabled" "false"
ini_set "$CUSTOM" "cloud_migration" "domain" "grafana.net"
ini_set "$CUSTOM" "server" "http_addr" "127.0.0.1"
ini_set "$CUSTOM" "server" "http_port" "3000"
ini_set "$CUSTOM" "server" "root_url" "%(protocol)s://%(domain)s:%(http_port)s/monitor"
ini_set "$CUSTOM" "server" "serve_from_sub_path" "true"
ini_set "$CUSTOM" "auth.jwt" "enabled" "true"
ini_set "$CUSTOM" "auth.jwt" "header_name" "X-JWT-Mamori-Grafana"
ini_set "$CUSTOM" "auth.jwt" "enable_login_token" "true"
ini_set "$CUSTOM" "auth.jwt" "auto_sign_up" "true"
ini_set "$CUSTOM" "auth.jwt" "url_login" "true"
ini_set "$CUSTOM" "auth.jwt" "username_claim" "sub"
ini_set "$CUSTOM" "auth.jwt" "email_claim" "email"
ini_set "$CUSTOM" "auth.jwt" "role_attribute_path" "role"
ini_set "$CUSTOM" "auth.jwt" "jwk_set_file" "/opt/mamori/grafana/conf/jwks.json"
echo "custom.ini updated"
EOF
}

apply_nginx_monitor() {
    $DOCKER exec -i "$CONTAINER" bash -s <<'EOF'
set -euo pipefail
SRC=/opt/mamori/config/nginx/monitoring.conf
DST=/etc/nginx/mamori/monitoring.conf
mkdir -p /opt/mamori/config/nginx /etc/nginx/mamori
if [[ ! -f "$SRC" ]] || ! grep -q 'location = /monitor' "$SRC" 2>/dev/null; then
    cat > "$SRC" <<'NGX'
# Menu opens /monitor?auth_token=... (no trailing slash). That would hit
# Phoenix ("Invalid URL" / placeholder) instead of Grafana.
location = /monitor {
    return 301 /monitor/$is_args$args;
}

location /monitor/ {
    proxy_set_header Host $http_host;
    proxy_pass http://localhost:3000;

   include /etc/nginx/mamori/monitor/*.conf;
}

# Proxy Grafana Live WebSocket connections.
location /monitor/api/live/ {
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_pass http://localhost:3000;
}
NGX
    echo "Wrote $SRC"
fi
rm -f "$DST"
cp "$SRC" "$DST"
if nginx -t >/dev/null 2>&1; then
    nginx -s reload
    echo "nginx reloaded with /monitor redirect"
else
    echo "WARNING: nginx -t failed after writing monitoring.conf" >&2
fi
EOF
}

restore_packaged_defaults() {
    if $DOCKER exec "$CONTAINER" grep -q '^\[cloud_migration\]' "${GRAFANA_HOME}/conf/defaults.ini" 2>/dev/null \
        && $DOCKER exec "$CONTAINER" grep -q '^\[secrets_manager\]' "${GRAFANA_HOME}/conf/defaults.ini" 2>/dev/null; then
        return 0
    fi
    echo "Restoring Grafana 13 packaged defaults.ini (DM had overwritten it with an older template) ..."
    tmp="$(mktemp)"
    if curl -fsSL --max-time 30 -o "$tmp" "https://raw.githubusercontent.com/grafana/grafana/v13.2.3/conf/defaults.ini"; then
        $DOCKER exec "$CONTAINER" cp -a "${GRAFANA_HOME}/conf/defaults.ini" "${GRAFANA_HOME}/conf/defaults.ini.dm.bak" || true
        $DOCKER cp "$tmp" "${CONTAINER}:${GRAFANA_HOME}/conf/defaults.ini"
        echo "defaults.ini restored from Grafana v13.2.3"
    else
        echo "WARNING: could not download Grafana 13.2.3 defaults.ini; custom.ini overlays only." >&2
    fi
    rm -f "$tmp"
}

wait_for_listen() {
    local BEFORE="$1"
    local deadline result="timeout" section="" now fresh
    deadline=$((SECONDS + WAIT_SECS))
    while [[ "$SECONDS" -lt "$deadline" ]]; do
        now="$(log_bytes)"
        if [[ "$now" -gt "$BEFORE" ]]; then
            fresh="$($DOCKER exec "$CONTAINER" tail -c +$((BEFORE + 1)) "$GRAFANA_LOG" 2>/dev/null || true)"
            if printf '%s\n' "$fresh" | grep -q 'Starting Grafana'; then
                section="$(latest_start)"
                if printf '%s\n' "$section" | grep -Eq 'missing configuration for current encryption provider|fatal error: newosproc|missing GMS domain|Error: ✗'; then
                    result="error"
                    break
                fi
                if $DOCKER logs --since 15s "$CONTAINER" 2>/dev/null | grep -q 'Error: ✗'; then
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
    echo "$result"
}

validate_grafana() {
    local FAILS=0 CUSTOM DEFAULTS section gpx headers body listen svst
    CUSTOM="${GRAFANA_HOME}/conf/custom.ini"
    DEFAULTS="${GRAFANA_HOME}/conf/defaults.ini"

    echo
    echo "=== Grafana 13 validate (${CONTAINER}) ==="

    ok() { echo "  OK: $*"; }
    fail() { echo "  FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

    expect_key() {
        local file="$1" section="$2" key="$3" expected="$4" label="$5"
        local got
        got="$(ini_get "$file" "$section" "$key")"
        if [[ "$(norm "$got")" == "$(norm "$expected")" ]]; then
            ok "$label ($got)"
        else
            fail "$label (got '${got:-<empty>}', expected '${expected}')"
        fi
    }

    expect_contains() {
        local file="$1" section="$2" key="$3" needle="$4" label="$5"
        local got
        got="$(ini_get "$file" "$section" "$key")"
        if [[ "$got" == *"$needle"* ]]; then
            ok "$label ($got)"
        else
            fail "$label (got '${got:-<empty>}', expected to contain '${needle}')"
        fi
    }

    expect_nonempty() {
        local file="$1" section="$2" key="$3" label="$4"
        local got
        got="$(ini_get "$file" "$section" "$key")"
        if [[ -n "${got// }" ]]; then
            ok "$label (set)"
        else
            fail "$label is empty"
        fi
    }

    if $DOCKER exec "$CONTAINER" grep -q '^\[secrets_manager\]' "$DEFAULTS" 2>/dev/null; then
        ok "packaged defaults.ini has [secrets_manager]"
    else
        fail "defaults.ini missing [secrets_manager] (need Grafana 13 packaged defaults, not a DM rewrite)"
    fi
    if $DOCKER exec "$CONTAINER" grep -q '^\[cloud_migration\]' "$DEFAULTS" 2>/dev/null; then
        ok "packaged defaults.ini has [cloud_migration]"
    else
        fail "defaults.ini missing [cloud_migration] (GMS client will fail to start)"
    fi
    if $DOCKER exec "$CONTAINER" test -f "${GRAFANA_HOME}/conf/.defaults.keep"; then
        ok "conf/.defaults.keep present"
    else
        fail "conf/.defaults.keep missing"
    fi

    expect_key "$CUSTOM" "secrets_manager" "encryption_provider" "secret_key.v1" "custom.ini secrets_manager.encryption_provider"
    expect_nonempty "$CUSTOM" "secrets_manager.encryption.secret_key.v1" "secret_key" "custom.ini secrets_manager secret_key"
    expect_key "$CUSTOM" "unified_alerting.state_history" "backend" "annotations" "custom.ini state_history.backend"
    expect_key "$CUSTOM" "unified_alerting.notification_history" "enabled" "false" "custom.ini notification_history.enabled"
    expect_key "$CUSTOM" "cloud_migration" "enabled" "false" "custom.ini cloud_migration.enabled"
    expect_key "$CUSTOM" "cloud_migration" "domain" "grafana.net" "custom.ini cloud_migration.domain"
    expect_key "$CUSTOM" "server" "http_addr" "127.0.0.1" "custom.ini server.http_addr"
    expect_key "$CUSTOM" "server" "http_port" "3000" "custom.ini server.http_port"
    expect_key "$CUSTOM" "server" "serve_from_sub_path" "true" "custom.ini server.serve_from_sub_path"
    expect_contains "$CUSTOM" "server" "root_url" "/monitor" "custom.ini server.root_url"
    expect_key "$CUSTOM" "auth.jwt" "enabled" "true" "custom.ini auth.jwt.enabled"
    expect_key "$CUSTOM" "auth.jwt" "url_login" "true" "custom.ini auth.jwt.url_login"
    expect_contains "$CUSTOM" "auth.jwt" "jwk_set_file" "jwks.json" "custom.ini auth.jwt.jwk_set_file"

    if $DOCKER exec "$CONTAINER" grep -q 'location = /monitor' /opt/mamori/config/nginx/monitoring.conf 2>/dev/null; then
        ok "image nginx monitoring.conf has location = /monitor"
    else
        fail "/opt/mamori/config/nginx/monitoring.conf missing location = /monitor"
    fi
    if $DOCKER exec "$CONTAINER" grep -q 'location = /monitor' /etc/nginx/mamori/monitoring.conf 2>/dev/null; then
        ok "runtime nginx monitoring.conf has location = /monitor"
    else
        fail "/etc/nginx/mamori/monitoring.conf missing location = /monitor (Phoenix will show Invalid URL)"
    fi

    if $DOCKER exec "$CONTAINER" test -s "${GRAFANA_HOME}/conf/jwks.json" 2>/dev/null; then
        ok "conf/jwks.json present"
    else
        fail "conf/jwks.json missing (grafana runit fetches http://localhost:4000/jwks/grafana.json)"
    fi

    svst="$($DOCKER exec "$CONTAINER" sv status grafana 2>/dev/null || true)"
    if [[ "$svst" == run:* ]]; then
        ok "sv status grafana: $svst"
    else
        fail "grafana runit is not run ($svst)"
    fi

    listen="$($DOCKER exec "$CONTAINER" sh -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -c :0BB8' || true)"
    if [[ "${listen:-0}" -gt 0 ]]; then
        ok "something is listening on port 3000"
    else
        fail "nothing listening on port 3000"
    fi

    section="$(latest_start)"
    if printf '%s\n' "$section" | grep -q 'HTTP Server Listen'; then
        ok "latest start logged HTTP Server Listen"
    else
        fail "latest start has no HTTP Server Listen"
    fi
    if printf '%s\n' "$section" | grep -q 'subUrl=/monitor'; then
        ok "latest start subUrl=/monitor"
    else
        fail "latest start missing subUrl=/monitor (serve_from_sub_path / root_url)"
    fi
    if printf '%s\n' "$section" | grep -q 'missing configuration for current encryption provider'; then
        fail "latest start still has encryption provider error"
    else
        ok "latest start has no encryption provider error"
    fi
    if printf '%s\n' "$section" | grep -q 'missing GMS domain'; then
        fail "latest start still has missing GMS domain"
    else
        ok "latest start has no missing GMS domain"
    fi
    if printf '%s\n' "$section" | grep -q 'fatal error: newosproc'; then
        fail "latest start still has fatal error: newosproc (pid leak)"
    else
        ok "latest start has no newosproc pid leak"
    fi
    if printf '%s\n' "$section" | grep -q 'Error: ✗'; then
        fail "latest start contains Error: ✗"
    else
        ok "latest start has no Error: ✗"
    fi

    gpx="$(count_gpx)"
    if [[ "$gpx" -le "$GPX_MAX" ]]; then
        ok "plugin processes in container: ${gpx} (limit ${GPX_MAX})"
    else
        fail "plugin processes in container: ${gpx} (limit ${GPX_MAX}) — Grafana is leaking gpx_* after crash-loop"
    fi

    headers="$($DOCKER exec "$CONTAINER" curl -skI --max-time 5 https://127.0.0.1/monitor 2>/dev/null \
        || $DOCKER exec "$CONTAINER" curl -sI --max-time 5 http://127.0.0.1/monitor 2>/dev/null \
        || true)"
    if printf '%s\n' "$headers" | grep -qiE '^HTTP/.* 301'; then
        ok "GET /monitor returns 301"
    else
        fail "GET /monitor did not 301 (Phoenix catch-all / Invalid URL). Headers: ${headers:-<empty>}"
    fi
    if printf '%s\n' "$headers" | grep -qiE '^Location:.*\/monitor\/'; then
        ok "GET /monitor Location is /monitor/"
    else
        fail "GET /monitor Location is not /monitor/"
    fi

    body="$($DOCKER exec "$CONTAINER" curl -skL --max-time 8 https://127.0.0.1/monitor/ 2>/dev/null \
        || $DOCKER exec "$CONTAINER" curl -sL --max-time 8 http://127.0.0.1/monitor/ 2>/dev/null \
        || true)"
    if printf '%s\n' "$body" | grep -q 'Invalid URL'; then
        fail "/monitor/ body contains Phoenix Invalid URL"
    else
        ok "/monitor/ is not Phoenix Invalid URL"
    fi

    echo
    if [[ "$FAILS" -gt 0 ]]; then
        echo "Validate FAILED with ${FAILS} check(s)." >&2
        return 1
    fi
    echo "Validate PASSED."
    return 0
}

if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
    validate_grafana
    exit $?
fi

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
apply_custom_ini

restore_packaged_defaults
$DOCKER exec "$CONTAINER" touch "${GRAFANA_HOME}/conf/.defaults.keep"
echo "Created conf/.defaults.keep so packaged defaults.ini is kept."

echo "Ensuring nginx /monitor → /monitor/ redirect ..."
apply_nginx_monitor

BEFORE="$(log_bytes)"
echo "Starting Grafana ..."
if ! $DOCKER exec "$CONTAINER" sv start grafana; then
    echo "sv start grafana returned an error; checking the log anyway ..." >&2
fi

result="$(wait_for_listen "$BEFORE")"

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
        ;;
    error)
        echo "Grafana failed again. The latest start still contains the encryption provider error, GMS, or fatal error: newosproc." >&2
        validate_grafana || true
        exit 1
        ;;
    *)
        echo "Timed out after ${WAIT_SECS}s waiting for HTTP Server Listen on the latest start." >&2
        validate_grafana || true
        exit 1
        ;;
esac

validate_grafana
exit $?
