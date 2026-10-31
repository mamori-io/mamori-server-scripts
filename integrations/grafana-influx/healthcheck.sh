#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Check that Mamori is writing metrics into InfluxDB (database mamori)
# and that Grafana's collectors are running.
#
# Writers POST line protocol to the server property influxdb_write_url.
# Grafana only reads InfluxDB; it does not collect metrics.
#
# Usage (on the Mamori host):
#   sudo ./healthcheck.sh
#   MAMORI_CONTAINER=mamori sudo ./healthcheck.sh
#   FRESH_SECS=180 sudo ./healthcheck.sh
#
# Exit 0 when every required check passes.
#

set -uo pipefail

DOCKER="${DOCKER:-sudo docker}"
CONTAINER="${MAMORI_CONTAINER:-mamori}"
FRESH_SECS="${FRESH_SECS:-120}"
APP_PROXY_FRESH_SECS="${APP_PROXY_FRESH_SECS:-300}"
LOG_TAIL="${LOG_TAIL:-80}"
FAILS=0
HUB_SERIES_OK=0
DM_SERIES_OK=0
WRITE_URL=""
QUERY_BASE=""
QUERY_DB="mamori"

usage() {
    cat <<'EOF'
Usage: healthcheck.sh

  Check Mamori → InfluxDB metric flow inside the Mamori container.
  Does not change configuration.

  MAMORI_CONTAINER        container name (default: mamori)
  DOCKER                  docker command (default: sudo docker)
  FRESH_SECS              max age for Hub, web-app, and Telegraf points (default: 120)
  APP_PROXY_FRESH_SECS    max age for HTTP app-proxy points (default: 300)
  LOG_TAIL                lines of mamori_fqod.log scanned for write errors (default: 80)

Collectors that must be writing when this host runs them:

  Hub (mamori_fqod)     measurement uptime          log /opt/mamori/var/log/fqod_metrics.log
                        failures                    log /opt/mamori/var/log/mamori_fqod.log
  Web app (dm)          process/ports service=dm    log /opt/mamori/var/log/dm_health_monitor.log
  Telegraf              measurement mem             runit stdout (docker logs); no log file
  InfluxDB              localhost:8086 db mamori    runit stdout (docker logs)
  Grafana               reads Influx only           /opt/mamori/grafana/data/log/grafana.log
  HTTP app proxy        process_uptime              only if influx.enabled=true

An empty influxdb_write_url makes Hub and the web app skip the POST with no error.
AIO value: http://127.0.0.1:8086/write?db=mamori

EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ $# -gt 0 ]]; then
    echo "Unknown argument: $1" >&2
    usage >&2
    exit 1
fi

ok() { echo "  OK: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
note() { echo "  --  $*"; }

dexec() {
    $DOCKER exec "$CONTAINER" "$@"
}

if ! $DOCKER inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "Container '${CONTAINER}' not found." >&2
    exit 1
fi
if [[ "$($DOCKER inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" != "true" ]]; then
    echo "Container '${CONTAINER}' is not running." >&2
    exit 1
fi

echo "=== Mamori → InfluxDB healthcheck (${CONTAINER}) ==="
echo

service_present() {
    dexec test -f "/etc/service/$1/run"
}

service_running() {
    local svst
    svst="$(dexec sv status "$1" 2>/dev/null || true)"
    [[ "$svst" == run:* ]]
}

check_service() {
    local name="$1" required="$2"
    if ! service_present "$name"; then
        if [[ "$required" == "required" ]]; then
            fail "runit service ${name} is not installed in ${CONTAINER}"
        else
            note "runit service ${name} is not in this container (normal on an HA app node)"
        fi
        return
    fi
    if service_running "$name"; then
        ok "sv status ${name} is run"
    else
        local svst
        svst="$(dexec sv status "$name" 2>/dev/null || true)"
        fail "sv status ${name} is not run (${svst:-no status})"
    fi
}

echo "Runit services"
check_service influxdb optional
check_service telegraf optional
check_service grafana optional
check_service mamori_fqod required
check_service dm required
echo

read_write_url() {
    local raw line
    raw="$(dexec msql.int "select value_property from rms.server_property where key_property = 'influxdb_write_url'" 2>/dev/null || true)"
    raw="${raw//\\/}"
    line="$(printf '%s\n' "$raw" | grep -oE 'https?://[^"[:space:]]+' | head -1 || true)"
    if [[ -n "$line" ]]; then
        printf '%s\n' "$line"
        return
    fi
    # msql.int Poison-encodes the row list. An empty list means the property is unset.
    if printf '%s\n' "$raw" | grep -q '\[\]'; then
        printf '\n'
        return
    fi
    raw="$(dexec /opt/mamori/mamori/dm/dm/bin/dm rpc 'v = Dm.Cirro.Query.as_cirro_internal(fn c -> Dm.Cirro.Query.select_value("select value_property from rms.server_property where key_property = '"'"'influxdb_write_url'"'"'", c) end); IO.puts(v || "")' 2>/dev/null || true)"
    raw="${raw//\\/}"
    printf '%s\n' "$raw" | grep -oE 'https?://[^"[:space:]]+' | head -1 || true
}

age_is_fresh() {
    [[ "$1" =~ ^[0-9]+$ && "$1" -le "$2" ]]
}

file_age_secs() {
    local path="$1"
    dexec sh -c "if [ -f '$path' ]; then now=\$(date +%s); m=\$(stat -c %Y '$path'); echo \$((now-m)); else echo missing; fi"
}

echo "Write URL"
WRITE_URL="$(read_write_url || true)"
if [[ -z "${WRITE_URL// }" ]]; then
    fail "influxdb_write_url is empty. Hub and the web app collector will not POST. Set it with: docker exec -it ${CONTAINER} msql \"call SET_SERVER_PROPERTY('influxdb_write_url', 'http://127.0.0.1:8086/write?db=mamori')\""
    QUERY_BASE="http://127.0.0.1:8086"
    QUERY_DB="mamori"
else
    ok "influxdb_write_url=${WRITE_URL}"
    QUERY_BASE="${WRITE_URL%%/write*}"
    QUERY_DB="$(printf '%s\n' "$WRITE_URL" | sed -n 's/.*[?&]db=\([^&]*\).*/\1/p')"
    QUERY_DB="${QUERY_DB:-mamori}"
    if [[ "$QUERY_BASE" == "$WRITE_URL" ]]; then
        fail "influxdb_write_url is not an Influx 1.x write URL (expected http://host:8086/write?db=mamori)"
        QUERY_BASE="http://127.0.0.1:8086"
    fi
fi
echo

influx_ping() {
    local base="$1" code
    code="$(dexec curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${base}/ping" 2>/dev/null || echo 000)"
    [[ "$code" == "204" || "$code" == "200" ]]
}

influx_query() {
    local q="$1"
    dexec curl -sG --max-time 10 "${QUERY_BASE}/query" \
        --data-urlencode "db=${QUERY_DB}" \
        --data-urlencode "q=${q}" 2>/dev/null || true
}

series_state() {
    local body="$1"
    if [[ -z "$body" ]]; then
        echo "empty"
    elif printf '%s\n' "$body" | grep -q '"error"'; then
        echo "error"
    elif printf '%s\n' "$body" | grep -q '"series"'; then
        echo "points"
    else
        echo "none"
    fi
}

echo "InfluxDB ${QUERY_BASE} database ${QUERY_DB}"
if influx_ping "$QUERY_BASE"; then
    ok "GET ${QUERY_BASE}/ping"
else
    fail "GET ${QUERY_BASE}/ping did not return 204 (InfluxDB not reachable from ${CONTAINER})"
fi

if service_present influxdb; then
    if influx_ping "http://127.0.0.1:8086"; then
        ok "local InfluxDB http://127.0.0.1:8086/ping"
    else
        fail "local InfluxDB is installed but http://127.0.0.1:8086/ping failed"
    fi
fi

check_series() {
    local label="$1" q="$2" which="$3"
    local body state err
    body="$(influx_query "$q")"
    state="$(series_state "$body")"
    case "$state" in
        points)
            ok "${label}: points in the last window"
            if [[ "$which" == "hub" ]]; then HUB_SERIES_OK=1; fi
            if [[ "$which" == "dm" ]]; then DM_SERIES_OK=1; fi
            ;;
        none)
            fail "${label}: no points (query: ${q})"
            ;;
        error)
            err="$(printf '%s\n' "$body" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p' | head -1)"
            fail "${label}: Influx error ${err:-$body}"
            ;;
        *)
            fail "${label}: no response from ${QUERY_BASE}/query"
            ;;
    esac
}

check_series "Hub uptime" "SELECT count(value) FROM uptime WHERE time > now() - ${FRESH_SECS}s" hub
check_series "Web app process service=dm" "SELECT count(value) FROM process WHERE \"service\" = 'dm' AND time > now() - ${FRESH_SECS}s" dm
check_series "Telegraf mem" "SELECT count(used_percent) FROM mem WHERE time > now() - ${FRESH_SECS}s" telegraf
echo

echo "Application proxy (optional)"
proxy_props="$(dexec sh -c 'ls /opt/mamori/server/http-proxy-*/config/monitoring.properties 2>/dev/null' || true)"
if [[ -z "${proxy_props// }" ]]; then
    note "no /opt/mamori/server/http-proxy-*/config/monitoring.properties (App Proxy dashboard stays empty)"
else
    enabled="$(dexec sh -c 'grep -lE "^[[:space:]]*influx.enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$" /opt/mamori/server/http-proxy-*/config/monitoring.properties 2>/dev/null' || true)"
    if [[ -z "${enabled// }" ]]; then
        note "application proxy monitoring.properties found; influx.enabled is not true"
        printf '%s\n' "$proxy_props" | while read -r p; do
            [[ -n "$p" ]] && note "  $p"
        done
    else
        ok "influx.enabled=true in: $(echo "$enabled" | tr '\n' ' ')"
        check_series "App proxy process_uptime" "SELECT count(value) FROM process_uptime WHERE time > now() - ${APP_PROXY_FRESH_SECS}s" app
    fi
fi
echo

echo "Collector logs"
metrics_age="$(file_age_secs /opt/mamori/var/log/fqod_metrics.log)"
if [[ "$metrics_age" == "missing" ]]; then
    fail "Hub metric log missing: /opt/mamori/var/log/fqod_metrics.log"
elif age_is_fresh "$metrics_age" "$FRESH_SECS"; then
    ok "fqod_metrics.log updated ${metrics_age}s ago (Hub is emitting line protocol)"
else
    fail "fqod_metrics.log is ${metrics_age:-unreadable} old (Hub HealthMonitor is not emitting)"
fi

dm_age="$(file_age_secs /opt/mamori/var/log/dm_health_monitor.log)"
if [[ "$dm_age" == "missing" ]]; then
    fail "web app collector log missing: /opt/mamori/var/log/dm_health_monitor.log"
elif age_is_fresh "$dm_age" "$FRESH_SECS"; then
    ok "dm_health_monitor.log updated ${dm_age}s ago (web app collector is ticking)"
else
    fail "dm_health_monitor.log is ${dm_age:-unreadable} old (web app collector is not ticking)"
fi

if [[ "$DM_SERIES_OK" -eq 0 ]] && age_is_fresh "$dm_age" "$FRESH_SECS"; then
    fail "web app collector log is moving but Influx has no service=dm points. influxdb_write_url is empty or the POST is not landing. DM does not log failed posts."
fi

fqod_tail="$(dexec tail -n "$LOG_TAIL" /opt/mamori/var/log/mamori_fqod.log 2>/dev/null || true)"
if printf '%s\n' "$fqod_tail" | grep -q 'Unable to write data to influxdb'; then
    if [[ "$HUB_SERIES_OK" -eq 1 ]]; then
        note "mamori_fqod.log tail still contains 'Unable to write data to influxdb', but Hub uptime points are fresh"
    else
        fail "mamori_fqod.log tail contains 'Unable to write data to influxdb' and Hub uptime points are missing"
        printf '%s\n' "$fqod_tail" | grep 'Unable to write data to influxdb' | tail -n 3 | sed 's/^/    /' >&2 || true
    fi
else
    ok "mamori_fqod.log tail has no 'Unable to write data to influxdb'"
fi

if service_present grafana; then
    glog_age="$(file_age_secs /opt/mamori/grafana/data/log/grafana.log)"
    if [[ "$glog_age" == "missing" ]]; then
        fail "Grafana log missing: /opt/mamori/grafana/data/log/grafana.log"
    else
        ok "grafana.log present (age ${glog_age}s)"
    fi
fi
echo

echo "Log commands"
cat <<EOF
  Hub line protocol:   $DOCKER exec $CONTAINER tail -n 20 /opt/mamori/var/log/fqod_metrics.log
  Hub write failures:  $DOCKER exec $CONTAINER grep -a 'Unable to write data to influxdb' /opt/mamori/var/log/mamori_fqod.log | tail
  Web app collector:   $DOCKER exec $CONTAINER tail -n 20 /opt/mamori/var/log/dm_health_monitor.log
  Grafana:             $DOCKER exec $CONTAINER tail -n 40 /opt/mamori/grafana/data/log/grafana.log
  Telegraf / Influx:   $DOCKER logs --tail 100 $CONTAINER
  Runit:               $DOCKER exec $CONTAINER sv status influxdb telegraf mamori_fqod dm grafana
  App proxy log:       /opt/mamori/server/http-proxy-<version>/log/proxy-<system>-<instance>.log
  App proxy switch:    influx.enabled in .../http-proxy-<version>/config/monitoring.properties
EOF
echo

if [[ "$FAILS" -gt 0 ]]; then
    echo "Healthcheck FAILED with ${FAILS} check(s)." >&2
    exit 1
fi
echo "Healthcheck PASSED."
exit 0
