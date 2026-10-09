#!/bin/bash
#
# Upgrade standalone HA shared-services Grafana (/opt/grafana) and InfluxDB (/opt/influxdb)
# containers to Grafana 13.2.3 and InfluxDB OSS 1.13.1.
#
# Usage (on the shared-services host as root):
#   ./upgrade-shared-monitoring.sh
#   ./upgrade-shared-monitoring.sh grafana
#   ./upgrade-shared-monitoring.sh influxdb
#   ./upgrade-shared-monitoring.sh --verify
#   ./upgrade-shared-monitoring.sh --verify grafana
#   ./upgrade-shared-monitoring.sh influxdb --verify
#

set -euo pipefail

GRAFANA_VERSION="${GRAFANA_VERSION:-13.2.3}"
INFLUXDB_VERSION="${INFLUXDB_VERSION:-1.13.1}"

GRAFANA_HOME="${GRAFANA_HOME:-/opt/grafana}"
INFLUXDB_HOME="${INFLUXDB_HOME:-/opt/influxdb}"
GRAFANA_CONTAINER="${GRAFANA_CONTAINER:-mamori-grafana}"
INFLUX_CONTAINER="${INFLUX_CONTAINER:-mamori-influx}"

GRAFANA_URL="https://dl.grafana.com/enterprise/release/grafana-enterprise-${GRAFANA_VERSION}.linux-amd64.tar.gz"
INFLUXDB_URL="https://dl.influxdata.com/influxdb/releases/v${INFLUXDB_VERSION}/influxdb-${INFLUXDB_VERSION}_linux_amd64.tar.gz"

VERIFY=0
TARGET="both"
VERIFY_ERRORS=0

usage() {
  cat <<EOF
Usage: $0 [both|grafana|influxdb] [--verify]
       $0 --verify [both|grafana|influxdb]

  (default)  Download and install target Grafana/InfluxDB binaries, restart containers.
  --verify   Check layout/containers/versions only; do not download or mutate.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --verify|-verify|verify)
      VERIFY=1
      ;;
    both|all|grafana|influxdb|influx)
      TARGET="$1"
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

ok() { echo "  OK: $*"; }
warn() { echo "  WARN: $*"; }
fail() {
  echo "  FAIL: $*" >&2
  VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
}

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]
}

grafana_reported_version() {
  local out=""
  if [ -x "${GRAFANA_HOME}/bin/grafana" ]; then
    out=$("${GRAFANA_HOME}/bin/grafana" --version 2>/dev/null || true)
    if [ -z "$out" ]; then
      out=$("${GRAFANA_HOME}/bin/grafana" version 2>/dev/null || true)
    fi
  fi
  # Prefer a clear x.y.z token from output.
  echo "$out" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

influx_reported_version() {
  local out=""
  if [ -x "${INFLUXDB_HOME}/influxd" ]; then
    out=$("${INFLUXDB_HOME}/influxd" version 2>/dev/null || true)
  fi
  echo "$out" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

verify_grafana() {
  echo "Verifying Grafana (target ${GRAFANA_VERSION}) ..."

  if [ ! -d "$GRAFANA_HOME" ]; then
    fail "home directory missing: ${GRAFANA_HOME}"
  else
    ok "home directory ${GRAFANA_HOME}"
  fi

  if [ ! -x "${GRAFANA_HOME}/bin/grafana" ]; then
    fail "missing executable ${GRAFANA_HOME}/bin/grafana"
  else
    ok "binary ${GRAFANA_HOME}/bin/grafana"
  fi

  if [ ! -d "${GRAFANA_HOME}/public" ]; then
    fail "missing ${GRAFANA_HOME}/public (Grafana web assets)"
  else
    ok "public assets present"
  fi

  if [ -x "${GRAFANA_HOME}/bin/grafana-server" ]; then
    ok "grafana-server present (native or shim)"
  else
    warn "grafana-server not present (upgrade will add a shim for older entrypoints)"
  fi

  if [ ! -d "${GRAFANA_HOME}/conf" ]; then
    fail "missing ${GRAFANA_HOME}/conf"
  else
    ok "conf directory present"
  fi

  if ! container_exists "$GRAFANA_CONTAINER"; then
    fail "docker container '${GRAFANA_CONTAINER}' not found"
  else
    ok "container ${GRAFANA_CONTAINER} exists"
    if container_running "$GRAFANA_CONTAINER"; then
      ok "container ${GRAFANA_CONTAINER} is running"
    else
      warn "container ${GRAFANA_CONTAINER} exists but is not running"
    fi
    ENTRY=$(docker inspect -f '{{join .Config.Entrypoint " "}}' "$GRAFANA_CONTAINER" 2>/dev/null || true)
    CMD=$(docker inspect -f '{{join .Config.Cmd " "}}' "$GRAFANA_CONTAINER" 2>/dev/null || true)
    echo "  entrypoint: ${ENTRY:-<none>}"
    echo "  cmd: ${CMD:-<none>}"
    if echo "${ENTRY} ${CMD}" | grep -Eq 'grafana([[:space:]]|$)|grafana-server'; then
      ok "entrypoint/cmd references grafana"
    else
      fail "entrypoint/cmd does not look like a Grafana start command"
    fi
    if echo "$ENTRY" | grep -q 'grafana-server'; then
      warn "entrypoint still uses grafana-server; upgrade will recreate with 'grafana server' if needed"
    fi
    MOUNTS=$(docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}; {{end}}' "$GRAFANA_CONTAINER" 2>/dev/null || true)
    if echo "$MOUNTS" | grep -q "$GRAFANA_HOME"; then
      ok "container mounts ${GRAFANA_HOME}"
    else
      fail "container does not mount ${GRAFANA_HOME} (mounts: ${MOUNTS:-none})"
    fi
  fi

  CURRENT=$(grafana_reported_version || true)
  if [ -n "$CURRENT" ]; then
    echo "  current version: ${CURRENT} (target ${GRAFANA_VERSION})"
    if [ "$CURRENT" = "$GRAFANA_VERSION" ]; then
      ok "already at target Grafana ${GRAFANA_VERSION}"
    else
      warn "not yet at target (will upgrade ${CURRENT} -> ${GRAFANA_VERSION})"
    fi
  else
    warn "could not determine current Grafana version from ${GRAFANA_HOME}/bin/grafana"
  fi
}

verify_influx() {
  echo "Verifying InfluxDB (target ${INFLUXDB_VERSION}) ..."

  if [ ! -d "$INFLUXDB_HOME" ]; then
    fail "home directory missing: ${INFLUXDB_HOME}"
  else
    ok "home directory ${INFLUXDB_HOME}"
  fi

  if [ ! -x "${INFLUXDB_HOME}/influxd" ]; then
    fail "missing executable ${INFLUXDB_HOME}/influxd"
  else
    ok "binary ${INFLUXDB_HOME}/influxd"
  fi

  if [ ! -f "${INFLUXDB_HOME}/influxdb.conf" ]; then
    warn "missing ${INFLUXDB_HOME}/influxdb.conf (container may still pass -config)"
  else
    ok "config ${INFLUXDB_HOME}/influxdb.conf"
  fi

  if ! container_exists "$INFLUX_CONTAINER"; then
    fail "docker container '${INFLUX_CONTAINER}' not found"
  else
    ok "container ${INFLUX_CONTAINER} exists"
    if container_running "$INFLUX_CONTAINER"; then
      ok "container ${INFLUX_CONTAINER} is running"
    else
      warn "container ${INFLUX_CONTAINER} exists but is not running"
    fi
    ENTRY=$(docker inspect -f '{{join .Config.Entrypoint " "}}' "$INFLUX_CONTAINER" 2>/dev/null || true)
    CMD=$(docker inspect -f '{{join .Config.Cmd " "}}' "$INFLUX_CONTAINER" 2>/dev/null || true)
    echo "  entrypoint: ${ENTRY:-<none>}"
    echo "  cmd: ${CMD:-<none>}"
    if echo "${ENTRY} ${CMD}" | grep -q 'influxd'; then
      ok "entrypoint/cmd references influxd"
    else
      fail "entrypoint/cmd does not look like an InfluxDB start command"
    fi
    MOUNTS=$(docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}; {{end}}' "$INFLUX_CONTAINER" 2>/dev/null || true)
    if echo "$MOUNTS" | grep -q "$INFLUXDB_HOME"; then
      ok "container mounts ${INFLUXDB_HOME}"
    else
      fail "container does not mount ${INFLUXDB_HOME} (mounts: ${MOUNTS:-none})"
    fi
  fi

  CURRENT=$(influx_reported_version || true)
  if [ -n "$CURRENT" ]; then
    echo "  current version: ${CURRENT} (target ${INFLUXDB_VERSION})"
    if [ "$CURRENT" = "$INFLUXDB_VERSION" ]; then
      ok "already at target InfluxDB ${INFLUXDB_VERSION}"
    else
      warn "not yet at target (will upgrade ${CURRENT} -> ${INFLUXDB_VERSION})"
    fi
  else
    warn "could not determine current InfluxDB version from ${INFLUXDB_HOME}/influxd"
  fi
}

run_verify() {
  case "$TARGET" in
    grafana) verify_grafana ;;
    influxdb|influx) verify_influx ;;
    both|all)
      verify_influx
      echo
      verify_grafana
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac

  echo
  if [ "$VERIFY_ERRORS" -gt 0 ]; then
    echo "Verify FAILED with ${VERIFY_ERRORS} error(s). Layout does not match what the upgrade expects." >&2
    exit 1
  fi
  echo "Verify PASSED. Installation looks like a Mamori HA shared-services monitoring layout."
  exit 0
}

upgrade_grafana() {
  if [ ! -d "$GRAFANA_HOME" ]; then
    echo "ERROR: ${GRAFANA_HOME} not found" >&2
    exit 1
  fi
  echo "Stopping ${GRAFANA_CONTAINER} ..."
  docker stop "$GRAFANA_CONTAINER" || true

  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' RETURN
  echo "Downloading Grafana ${GRAFANA_VERSION} ..."
  curl -fL --retry 3 -o "$WORK/grafana.tgz" "$GRAFANA_URL"
  tar xzf "$WORK/grafana.tgz" -C "$WORK"
  SRC="$WORK/grafana-${GRAFANA_VERSION}"

  rm -rf "${GRAFANA_HOME}/bin" "${GRAFANA_HOME}/public"
  cp -a "$SRC/bin" "$SRC/public" "$GRAFANA_HOME/"
  printf '%s\n' '#!/bin/sh' 'exec "$(dirname "$0")/grafana" server "$@"' > "${GRAFANA_HOME}/bin/grafana-server"
  chmod +x "${GRAFANA_HOME}/bin/grafana-server"

  # Recreate container with Grafana 13 entrypoint if an old grafana-server entrypoint exists.
  if docker inspect "$GRAFANA_CONTAINER" >/dev/null 2>&1; then
    ENTRY=$(docker inspect -f '{{.Config.Entrypoint}}' "$GRAFANA_CONTAINER" 2>/dev/null || true)
    if echo "$ENTRY" | grep -q grafana-server; then
      echo "Recreating ${GRAFANA_CONTAINER} with 'grafana server' entrypoint ..."
      docker rm "$GRAFANA_CONTAINER"
      docker create --log-opt max-size=10m --log-opt max-file=5 --net host \
        --volume "${GRAFANA_HOME}/:${GRAFANA_HOME}" \
        --name "$GRAFANA_CONTAINER" --restart always \
        --workdir "$GRAFANA_HOME" \
        --entrypoint "${GRAFANA_HOME}/bin/grafana" \
        mamori-grafana-alpine server --homepath="${GRAFANA_HOME}/"
    fi
  fi

  docker start "$GRAFANA_CONTAINER"
  echo "Grafana ${GRAFANA_VERSION} upgrade complete."
}

upgrade_influx() {
  if [ ! -d "$INFLUXDB_HOME" ]; then
    echo "ERROR: ${INFLUXDB_HOME} not found" >&2
    exit 1
  fi
  echo "Stopping ${INFLUX_CONTAINER} ..."
  docker stop "$INFLUX_CONTAINER" || true

  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' RETURN
  echo "Downloading InfluxDB ${INFLUXDB_VERSION} ..."
  curl -fL --retry 3 -o "$WORK/influx.tgz" "$INFLUXDB_URL"
  tar xzf "$WORK/influx.tgz" -C "$WORK"
  SRC="$WORK/influxdb-${INFLUXDB_VERSION}"
  cp -a "$SRC/influxd" "$SRC/influx" "$SRC/influx_inspect" "$INFLUXDB_HOME/"

  docker start "$INFLUX_CONTAINER"
  echo "InfluxDB ${INFLUXDB_VERSION} upgrade complete."
  "$INFLUXDB_HOME/influxd" version || true
}

if [ "$VERIFY" -eq 1 ]; then
  run_verify
fi

case "$TARGET" in
  grafana) upgrade_grafana ;;
  influxdb|influx) upgrade_influx ;;
  both|all)
    upgrade_influx
    upgrade_grafana
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
