#!/bin/bash
#
# Discover, verify, and upgrade HA shared-services Grafana + InfluxDB.
#
# Flow:
#   1) sudo ./upgrade-shared-monitoring.sh --verify
#        → discovers layout, writes monitoring-upgrade.env profile
#   2) sudo ./upgrade-shared-monitoring.sh
#        → upgrades using that profile (refuses to run without it)
#
# Target versions: Grafana Enterprise 13.2.3, InfluxDB OSS 1.13.1
#
# Usage (on the shared-services / monitoring host as root):
#   ./upgrade-shared-monitoring.sh --verify
#   ./upgrade-shared-monitoring.sh --verify grafana
#   ./upgrade-shared-monitoring.sh
#   ./upgrade-shared-monitoring.sh grafana
#   ./upgrade-shared-monitoring.sh --config /path/to/monitoring-upgrade.env
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GRAFANA_VERSION="${GRAFANA_VERSION:-13.2.3}"
INFLUXDB_VERSION="${INFLUXDB_VERSION:-1.13.1}"

GRAFANA_URL="https://dl.grafana.com/enterprise/release/grafana-enterprise-${GRAFANA_VERSION}.linux-amd64.tar.gz"
INFLUXDB_URL="https://dl.influxdata.com/influxdb/releases/v${INFLUXDB_VERSION}/influxdb-${INFLUXDB_VERSION}_linux_amd64.tar.gz"

VERIFY=0
TARGET="both"
PROFILE_PATH="${MONITORING_PROFILE:-${SCRIPT_DIR}/monitoring-upgrade.env}"
VERIFY_ERRORS=0

# Discovered / profile fields (defaults before discover/load)
GRAFANA_MODE=none
GRAFANA_HOME=
GRAFANA_CONTAINER=
GRAFANA_IMAGE=
GRAFANA_NETWORK_MODE=
GRAFANA_HOST_BIND=
GRAFANA_NEEDS_ENTRYPOINT_FIX=0
GRAFANA_CURRENT_VERSION=
INFLUX_MODE=none
INFLUX_HOME=
INFLUX_BIN=
INFLUX_CONFIG=
INFLUX_CONTAINER=
INFLUX_SERVICE=
INFLUX_CURRENT_VERSION=

usage() {
  cat <<EOF
Usage: $0 [both|grafana|influxdb] [--verify] [--config PATH]

  --verify   Discover install layout, validate it, write a profile file.
             Does not download or mutate binaries.
  (default)  Upgrade using the profile from a prior --verify.
  --config   Profile path (default: ${SCRIPT_DIR}/monitoring-upgrade.env
             or \$MONITORING_PROFILE).

Supported Grafana modes: host-tree, container-fs
Supported Influx modes:  host-tree, host-package, container
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --verify|-verify|verify)
      VERIFY=1
      ;;
    --config|-c)
      shift
      PROFILE_PATH="${1:-}"
      if [ -z "$PROFILE_PATH" ]; then
        echo "ERROR: --config requires a path" >&2
        exit 1
      fi
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

extract_version() {
  echo "$1" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

grafana_version_from_path() {
  local home="$1" out=""
  if [ -x "${home}/bin/grafana" ]; then
    out=$("${home}/bin/grafana" --version 2>/dev/null || true)
    [ -n "$out" ] || out=$("${home}/bin/grafana" version 2>/dev/null || true)
  elif [ -x "${home}/bin/grafana-server" ]; then
    out=$("${home}/bin/grafana-server" -v 2>/dev/null || true)
  fi
  extract_version "$out"
}

grafana_version_in_container() {
  local c="$1" home="$2" out=""
  out=$(docker exec "$c" "${home}/bin/grafana" --version 2>/dev/null || true)
  [ -n "$out" ] || out=$(docker exec "$c" "${home}/bin/grafana" version 2>/dev/null || true)
  [ -n "$out" ] || out=$(docker exec "$c" "${home}/bin/grafana-server" -v 2>/dev/null || true)
  extract_version "$out"
}

influx_version_from_bin() {
  local bin="$1" out=""
  if [ -x "$bin" ]; then
    out=$("$bin" version 2>/dev/null || true)
  fi
  extract_version "$out"
}

# Return host path bind-mounted to dest inside container, or empty.
container_bind_source_for() {
  local c="$1" dest="$2"
  docker inspect -f '{{range .Mounts}}{{println .Source .Destination}}{{end}}' "$c" 2>/dev/null \
    | while read -r src d; do
        [ "$d" = "$dest" ] && echo "$src" && break
      done
}

path_has_grafana() {
  local home="$1"
  [ -x "${home}/bin/grafana" ] || [ -x "${home}/bin/grafana-server" ]
}

container_has_grafana_at() {
  local c="$1" home="$2"
  docker exec "$c" test -x "${home}/bin/grafana" 2>/dev/null \
    || docker exec "$c" test -x "${home}/bin/grafana-server" 2>/dev/null
}

discover_grafana() {
  echo "Discovering Grafana ..."
  GRAFANA_MODE=none
  GRAFANA_HOME=
  GRAFANA_CONTAINER=
  GRAFANA_IMAGE=
  GRAFANA_NETWORK_MODE=
  GRAFANA_HOST_BIND=
  GRAFANA_NEEDS_ENTRYPOINT_FIX=0
  GRAFANA_CURRENT_VERSION=

  local c home bind entry cmd net image

  # Prefer known container names, then any running container with grafana in the name/image.
  local candidates=()
  for c in mamori-grafana grafana; do
    container_exists "$c" && candidates+=("$c")
  done
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    local seen=0
    for x in "${candidates[@]:-}"; do [ "$x" = "$c" ] && seen=1 && break; done
    [ "$seen" -eq 0 ] && candidates+=("$c")
  done < <(docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null | awk '/grafana/ {print $1}')

  for c in "${candidates[@]:-}"; do
    for home in /opt/grafana /opt/mamori/grafana; do
      if container_has_grafana_at "$c" "$home"; then
        GRAFANA_CONTAINER="$c"
        GRAFANA_HOME="$home"
        GRAFANA_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null || true)
        GRAFANA_NETWORK_MODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$c" 2>/dev/null || true)
        bind=$(container_bind_source_for "$c" "$home" || true)
        entry=$(docker inspect -f '{{join .Config.Entrypoint " "}}' "$c" 2>/dev/null || true)
        cmd=$(docker inspect -f '{{join .Config.Cmd " "}}' "$c" 2>/dev/null || true)
        if echo "$entry $cmd" | grep -q 'grafana-server'; then
          GRAFANA_NEEDS_ENTRYPOINT_FIX=1
        fi
        # Also detect runit inside phusion/my_init images
        if docker exec "$c" grep -q grafana-server /etc/service/grafana/run 2>/dev/null; then
          GRAFANA_NEEDS_ENTRYPOINT_FIX=1
        fi
        if [ -n "$bind" ] && path_has_grafana "$bind"; then
          GRAFANA_MODE=host-tree
          GRAFANA_HOST_BIND="$bind"
          GRAFANA_HOME="$bind"
          GRAFANA_CURRENT_VERSION=$(grafana_version_from_path "$bind" || true)
          ok "Grafana host-tree: host ${bind} mounted into ${c}:${home}"
        else
          GRAFANA_MODE=container-fs
          GRAFANA_HOST_BIND=
          GRAFANA_CURRENT_VERSION=$(grafana_version_in_container "$c" "$home" || true)
          ok "Grafana container-fs: ${c}:${home} (image ${GRAFANA_IMAGE})"
        fi
        echo "  network=${GRAFANA_NETWORK_MODE:-?} entrypoint='${entry:-}' cmd='${cmd:-}'"
        echo "  current version: ${GRAFANA_CURRENT_VERSION:-unknown} (target ${GRAFANA_VERSION})"
        return 0
      fi
    done
  done

  # Host-only tree (no container found yet)
  for home in /opt/grafana /opt/mamori/grafana; do
    if path_has_grafana "$home"; then
      GRAFANA_MODE=host-tree
      GRAFANA_HOME="$home"
      GRAFANA_HOST_BIND="$home"
      GRAFANA_CURRENT_VERSION=$(grafana_version_from_path "$home" || true)
      warn "Grafana host-tree at ${home} but no matching docker container found"
      echo "  current version: ${GRAFANA_CURRENT_VERSION:-unknown} (target ${GRAFANA_VERSION})"
      return 0
    fi
  done

  fail "could not find Grafana under /opt/grafana, /opt/mamori/grafana, or a grafana docker container"
}

discover_influx() {
  echo "Discovering InfluxDB ..."
  INFLUX_MODE=none
  INFLUX_HOME=
  INFLUX_BIN=
  INFLUX_CONFIG=
  INFLUX_CONTAINER=
  INFLUX_SERVICE=
  INFLUX_CURRENT_VERSION=

  local c

  for c in mamori-influx influxdb influx; do
    if container_exists "$c" && docker exec "$c" sh -c 'command -v influxd >/dev/null || test -x /opt/influxdb/influxd || test -x /usr/bin/influxd' 2>/dev/null; then
      INFLUX_CONTAINER="$c"
      if docker exec "$c" test -x /opt/influxdb/influxd 2>/dev/null; then
        INFLUX_MODE=container
        INFLUX_HOME=/opt/influxdb
        INFLUX_BIN=/opt/influxdb/influxd
        if docker exec "$c" test -f /opt/influxdb/influxdb.conf 2>/dev/null; then
          INFLUX_CONFIG=/opt/influxdb/influxdb.conf
        fi
        local bind
        bind=$(container_bind_source_for "$c" /opt/influxdb || true)
        if [ -n "$bind" ] && [ -x "${bind}/influxd" ]; then
          INFLUX_MODE=host-tree
          INFLUX_HOME="$bind"
          INFLUX_BIN="${bind}/influxd"
          [ -f "${bind}/influxdb.conf" ] && INFLUX_CONFIG="${bind}/influxdb.conf"
          INFLUX_CURRENT_VERSION=$(influx_version_from_bin "$INFLUX_BIN" || true)
          ok "InfluxDB host-tree: host ${bind} via container ${c}"
        else
          INFLUX_CURRENT_VERSION=$(extract_version "$(docker exec "$c" "$INFLUX_BIN" version 2>/dev/null || true)")
          ok "InfluxDB container: ${c}:${INFLUX_BIN}"
        fi
      else
        INFLUX_MODE=container
        INFLUX_BIN=$(docker exec "$c" sh -c 'command -v influxd' 2>/dev/null || echo /usr/bin/influxd)
        INFLUX_CURRENT_VERSION=$(extract_version "$(docker exec "$c" influxd version 2>/dev/null || true)")
        ok "InfluxDB container: ${c} (${INFLUX_BIN})"
      fi
      echo "  current version: ${INFLUX_CURRENT_VERSION:-unknown} (target ${INFLUXDB_VERSION})"
      return 0
    fi
  done

  if [ -x /opt/influxdb/influxd ]; then
    INFLUX_MODE=host-tree
    INFLUX_HOME=/opt/influxdb
    INFLUX_BIN=/opt/influxdb/influxd
    [ -f /opt/influxdb/influxdb.conf ] && INFLUX_CONFIG=/opt/influxdb/influxdb.conf
    INFLUX_CURRENT_VERSION=$(influx_version_from_bin "$INFLUX_BIN" || true)
    if container_exists mamori-influx; then
      INFLUX_CONTAINER=mamori-influx
    fi
    ok "InfluxDB host-tree at /opt/influxdb"
    echo "  current version: ${INFLUX_CURRENT_VERSION:-unknown} (target ${INFLUXDB_VERSION})"
    return 0
  fi

  if [ -x /usr/bin/influxd ]; then
    INFLUX_MODE=host-package
    INFLUX_BIN=/usr/bin/influxd
    [ -f /etc/influxdb/influxdb.conf ] && INFLUX_CONFIG=/etc/influxdb/influxdb.conf
    INFLUX_CURRENT_VERSION=$(influx_version_from_bin "$INFLUX_BIN" || true)
    if systemctl list-unit-files influxdb.service >/dev/null 2>&1; then
      INFLUX_SERVICE=influxdb
    elif systemctl list-unit-files influxd.service >/dev/null 2>&1; then
      INFLUX_SERVICE=influxd
    fi
    ok "InfluxDB host-package: ${INFLUX_BIN} (service=${INFLUX_SERVICE:-none})"
    echo "  current version: ${INFLUX_CURRENT_VERSION:-unknown} (target ${INFLUXDB_VERSION})"
    return 0
  fi

  fail "could not find InfluxDB (/opt/influxdb, /usr/bin/influxd, or influx docker container)"
}

validate_discovered_for_target() {
  case "$TARGET" in
    grafana)
      if [ "$GRAFANA_MODE" = "none" ]; then
        fail "Grafana is required for target=grafana but was not discovered"
      fi
      ;;
    influxdb|influx)
      if [ "$INFLUX_MODE" = "none" ]; then
        fail "InfluxDB is required for target=influxdb but was not discovered"
      fi
      ;;
    both|all)
      if [ "$GRAFANA_MODE" = "none" ]; then
        fail "Grafana was not discovered (required for target=both)"
      fi
      if [ "$INFLUX_MODE" = "none" ]; then
        fail "InfluxDB was not discovered (required for target=both)"
      fi
      ;;
  esac

  if [ "$GRAFANA_MODE" != "none" ]; then
    if [ "$GRAFANA_MODE" = "host-tree" ] && [ ! -d "$GRAFANA_HOME" ]; then
      fail "Grafana home missing: ${GRAFANA_HOME}"
    fi
    if [ "$GRAFANA_MODE" = "container-fs" ]; then
      if [ -z "$GRAFANA_CONTAINER" ] || ! container_exists "$GRAFANA_CONTAINER"; then
        fail "Grafana container missing: ${GRAFANA_CONTAINER:-<unset>}"
      fi
    fi
    if [ -n "$GRAFANA_CURRENT_VERSION" ] && [ "$GRAFANA_CURRENT_VERSION" = "$GRAFANA_VERSION" ]; then
      ok "Grafana already at target ${GRAFANA_VERSION}"
    elif [ -n "$GRAFANA_CURRENT_VERSION" ]; then
      warn "Grafana will upgrade ${GRAFANA_CURRENT_VERSION} -> ${GRAFANA_VERSION}"
    fi
  fi

  if [ "$INFLUX_MODE" != "none" ]; then
    case "$INFLUX_MODE" in
      host-tree)
        [ -x "${INFLUX_HOME}/influxd" ] || fail "missing ${INFLUX_HOME}/influxd"
        ;;
      host-package)
        [ -x "$INFLUX_BIN" ] || fail "missing ${INFLUX_BIN}"
        ;;
      container)
        [ -n "$INFLUX_CONTAINER" ] && container_exists "$INFLUX_CONTAINER" \
          || fail "Influx container missing: ${INFLUX_CONTAINER:-<unset>}"
        ;;
    esac
    if [ -n "$INFLUX_CURRENT_VERSION" ] && [ "$INFLUX_CURRENT_VERSION" = "$INFLUXDB_VERSION" ]; then
      ok "InfluxDB already at target ${INFLUXDB_VERSION}"
    elif [ -n "$INFLUX_CURRENT_VERSION" ]; then
      warn "InfluxDB will upgrade ${INFLUX_CURRENT_VERSION} -> ${INFLUXDB_VERSION}"
    fi
  fi
}

write_profile() {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<EOF
# Generated by upgrade-shared-monitoring.sh --verify
# Do not edit unless you know the layout. Re-run --verify to refresh.
PROFILE_VERSION=1
DISCOVERED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOSTNAME=$(hostname -f 2>/dev/null || hostname)

TARGET_GRAFANA_VERSION=${GRAFANA_VERSION}
TARGET_INFLUXDB_VERSION=${INFLUXDB_VERSION}

GRAFANA_MODE=${GRAFANA_MODE}
GRAFANA_HOME=${GRAFANA_HOME}
GRAFANA_CONTAINER=${GRAFANA_CONTAINER}
GRAFANA_IMAGE=${GRAFANA_IMAGE}
GRAFANA_NETWORK_MODE=${GRAFANA_NETWORK_MODE}
GRAFANA_HOST_BIND=${GRAFANA_HOST_BIND}
GRAFANA_NEEDS_ENTRYPOINT_FIX=${GRAFANA_NEEDS_ENTRYPOINT_FIX}
GRAFANA_CURRENT_VERSION=${GRAFANA_CURRENT_VERSION}

INFLUX_MODE=${INFLUX_MODE}
INFLUX_HOME=${INFLUX_HOME}
INFLUX_BIN=${INFLUX_BIN}
INFLUX_CONFIG=${INFLUX_CONFIG}
INFLUX_CONTAINER=${INFLUX_CONTAINER}
INFLUX_SERVICE=${INFLUX_SERVICE}
INFLUX_CURRENT_VERSION=${INFLUX_CURRENT_VERSION}
EOF
  mkdir -p "$(dirname "$PROFILE_PATH")"
  mv "$tmp" "$PROFILE_PATH"
  chmod 644 "$PROFILE_PATH"
  echo
  echo "Wrote profile: ${PROFILE_PATH}"
}

load_profile() {
  if [ ! -f "$PROFILE_PATH" ]; then
    echo "ERROR: profile not found: ${PROFILE_PATH}" >&2
    echo "Run: $0 --verify   (then re-run the upgrade)" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  . "$PROFILE_PATH"
  set +a
  echo "Loaded profile: ${PROFILE_PATH} (discovered ${DISCOVERED_AT:-unknown} on ${HOSTNAME:-unknown})"
  echo "  Grafana mode=${GRAFANA_MODE} home=${GRAFANA_HOME:--} container=${GRAFANA_CONTAINER:--}"
  echo "  Influx  mode=${INFLUX_MODE} bin=${INFLUX_BIN:--} container=${INFLUX_CONTAINER:--}"
}

assert_profile_usable() {
  case "$TARGET" in
    grafana|both|all)
      if [ "${GRAFANA_MODE:-none}" = "none" ] || [ -z "${GRAFANA_MODE:-}" ]; then
        echo "ERROR: profile has no Grafana layout. Re-run --verify on this host." >&2
        exit 1
      fi
      ;;
  esac
  case "$TARGET" in
    influxdb|influx|both|all)
      if [ "${INFLUX_MODE:-none}" = "none" ] || [ -z "${INFLUX_MODE:-}" ]; then
        echo "ERROR: profile has no InfluxDB layout. Re-run --verify on this host." >&2
        exit 1
      fi
      ;;
  esac
}

download_grafana_extract() {
  local work="$1"
  # Status on stderr so $(...) only captures the extract path.
  echo "Downloading Grafana ${GRAFANA_VERSION} ..." >&2
  curl -fL --retry 3 -o "${work}/grafana.tgz" "$GRAFANA_URL"
  tar xzf "${work}/grafana.tgz" -C "$work"
  echo "${work}/grafana-${GRAFANA_VERSION}"
}

download_influx_extract() {
  local work="$1"
  # Status on stderr so $(...) only captures the extract path.
  echo "Downloading InfluxDB ${INFLUXDB_VERSION} ..." >&2
  curl -fL --retry 3 -o "${work}/influx.tgz" "$INFLUXDB_URL"
  tar xzf "${work}/influx.tgz" -C "$work"
  echo "${work}/influxdb-${INFLUXDB_VERSION}"
}

install_grafana_shim() {
  local home="$1"
  printf '%s\n' '#!/bin/sh' 'exec "$(dirname "$0")/grafana" server "$@"' > "${home}/bin/grafana-server"
  chmod +x "${home}/bin/grafana-server"
}

# Grafana 13 requires modern defaults.ini (secrets_manager, alerting sections).
# Binary-only upgrades leave a stale defaults.ini and crash (502 via nginx).
# Install package defaults.ini and ensure custom.ini has Mamori-critical overrides.
ini_get_key() {
  local file="$1" section="$2" key="$3"
  awk -v sec="[$section]" -v key="$key" '
    $0 == sec { insec=1; next }
    /^\[/ { insec=0 }
    insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, ""); print; exit
    }
  ' "$file" 2>/dev/null || true
}

ensure_grafana_custom_overrides() {
  # Args: path to custom.ini, path to old defaults (for secret_key harvest)
  local custom="$1" old_defaults="${2:-}"
  local secret=""
  mkdir -p "$(dirname "$custom")"
  touch "$custom"

  if [ -n "$old_defaults" ] && [ -f "$old_defaults" ]; then
    secret=$(ini_get_key "$old_defaults" security secret_key)
  fi
  if [ -z "$secret" ] && [ -f "$custom" ]; then
    secret=$(ini_get_key "$custom" security secret_key)
  fi
  if [ -z "$secret" ]; then
    secret=$(ini_get_key "$custom" "secrets_manager.encryption.secret_key.v1" secret_key)
  fi

  # Append missing Grafana-13 / Mamori sections (do not rewrite whole file).
  if ! grep -q '^\[secrets_manager\]' "$custom" 2>/dev/null; then
    {
      echo ""
      echo "[secrets_manager]"
      echo "encryption_provider = secret_key.v1"
    } >> "$custom"
  fi
  if ! grep -q '^\[secrets_manager.encryption.secret_key.v1\]' "$custom" 2>/dev/null; then
    {
      echo ""
      echo "[secrets_manager.encryption.secret_key.v1]"
      if [ -n "$secret" ]; then
        echo "secret_key = ${secret}"
      else
        echo "; set secret_key to match [security] secret_key"
        echo "secret_key ="
      fi
    } >> "$custom"
  fi
  if ! grep -q '^\[unified_alerting.state_history\]' "$custom" 2>/dev/null; then
    {
      echo ""
      echo "[unified_alerting.state_history]"
      echo "backend = annotations"
    } >> "$custom"
  fi
}

fix_grafana_conf_host() {
  local home="$1" src="$2"
  local conf="${home}/conf"
  mkdir -p "$conf"
  if [ -f "${conf}/defaults.ini" ]; then
    cp -a "${conf}/defaults.ini" "${conf}/defaults.ini.pre-upgrade.bak"
  fi
  if [ -f "${src}/conf/defaults.ini" ]; then
    cp -a "${src}/conf/defaults.ini" "${conf}/defaults.ini"
    cp -a "${src}/conf/defaults.ini" "${conf}/defaults.ini.upstream"
  fi
  ensure_grafana_custom_overrides "${conf}/custom.ini" "${conf}/defaults.ini.pre-upgrade.bak"
}

fix_grafana_conf_container() {
  local c="$1" home="$2" src="$3"
  local stage old
  stage=$(mktemp -d)
  old=$(mktemp)
  mkdir -p "${stage}/conf"
  if docker exec "$c" test -f "${home}/conf/defaults.ini" 2>/dev/null; then
    docker cp "${c}:${home}/conf/defaults.ini" "$old" || true
    docker exec "$c" cp "${home}/conf/defaults.ini" "${home}/conf/defaults.ini.pre-upgrade.bak" || true
  fi
  if [ -f "${src}/conf/defaults.ini" ]; then
    docker cp "${src}/conf/defaults.ini" "${c}:${home}/conf/defaults.ini"
    docker cp "${src}/conf/defaults.ini" "${c}:${home}/conf/defaults.ini.upstream"
  fi
  if docker exec "$c" test -f "${home}/conf/custom.ini" 2>/dev/null; then
    docker cp "${c}:${home}/conf/custom.ini" "${stage}/custom.ini"
  else
    : > "${stage}/custom.ini"
  fi
  ensure_grafana_custom_overrides "${stage}/custom.ini" "$old"
  docker cp "${stage}/custom.ini" "${c}:${home}/conf/custom.ini"
  rm -rf "$stage" "$old"
}

fix_grafana_tree() {
  local home="$1" src="$2"
  rm -rf "${home}/bin" "${home}/public"
  cp -a "${src}/bin" "${src}/public" "${home}/"
  install_grafana_shim "$home"
  fix_grafana_conf_host "$home" "$src"
}

fix_grafana_into_container() {
  local c="$1" home="$2" src="$3"
  local stage
  stage=$(mktemp -d)
  cp -a "${src}/bin" "${src}/public" "$stage/"
  printf '%s\n' '#!/bin/sh' 'exec "$(dirname "$0")/grafana" server "$@"' > "${stage}/bin/grafana-server"
  chmod +x "${stage}/bin/grafana-server"
  docker exec "$c" rm -rf "${home}/bin" "${home}/public"
  docker cp "${stage}/bin" "${c}:${home}/"
  docker cp "${stage}/public" "${c}:${home}/"
  fix_grafana_conf_container "$c" "$home" "$src"
  # Fix runit if present
  if docker exec "$c" test -f /etc/service/grafana/run 2>/dev/null; then
    docker exec "$c" sh -c "cat > /etc/service/grafana/run <<'EOF'
#!/bin/sh
exec ${home}/bin/grafana server --homepath=${home}/
EOF
chmod +x /etc/service/grafana/run"
  fi
  rm -rf "$stage"
}

maybe_fix_grafana_entrypoint() {
  local c="$1" home="$2"
  [ -n "$c" ] || return 0
  container_exists "$c" || return 0
  local entry image net
  entry=$(docker inspect -f '{{json .Config.Entrypoint}}' "$c" 2>/dev/null || true)
  if ! echo "$entry" | grep -q grafana-server; then
    return 0
  fi
  image=$(docker inspect -f '{{.Config.Image}}' "$c")
  net=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$c")
  echo "Recreating ${c} with 'grafana server' entrypoint ..."
  docker stop "$c" || true
  docker rm "$c"
  if [ "$GRAFANA_MODE" = "host-tree" ]; then
    docker create --log-opt max-size=10m --log-opt max-file=5 \
      --network "$net" \
      --volume "${home}/:${home}" \
      --name "$c" --restart always \
      --workdir "$home" \
      --entrypoint "${home}/bin/grafana" \
      "$image" server --homepath="${home}/"
  else
    # container-fs: keep image layers; prefer my_init if that was the prior cmd
    docker create --log-opt max-size=10m --log-opt max-file=5 \
      --network "$net" \
      --name "$c" --restart always \
      "$image" /sbin/my_init
  fi
}

upgrade_grafana() {
  echo "=== Upgrading Grafana (${GRAFANA_MODE}) → ${GRAFANA_VERSION} ==="
  local work src ver=""
  work=$(mktemp -d)
  src=$(download_grafana_extract "$work")

  case "$GRAFANA_MODE" in
    host-tree)
      if [ -n "${GRAFANA_CONTAINER:-}" ]; then
        echo "Stopping ${GRAFANA_CONTAINER} ..."
        docker stop "$GRAFANA_CONTAINER" || true
      fi
      fix_grafana_tree "$GRAFANA_HOME" "$src"
      if [ "${GRAFANA_NEEDS_ENTRYPOINT_FIX:-0}" = "1" ] && [ -n "${GRAFANA_CONTAINER:-}" ]; then
        maybe_fix_grafana_entrypoint "$GRAFANA_CONTAINER" "$GRAFANA_HOME"
      fi
      if [ -n "${GRAFANA_CONTAINER:-}" ]; then
        docker start "$GRAFANA_CONTAINER"
      fi
      ver=$(grafana_version_from_path "$GRAFANA_HOME" || true)
      ;;
    container-fs)
      echo "Stopping ${GRAFANA_CONTAINER} ..."
      docker stop "$GRAFANA_CONTAINER" || true
      docker start "$GRAFANA_CONTAINER"
      # Wait briefly for container to accept docker exec / cp
      sleep 2
      fix_grafana_into_container "$GRAFANA_CONTAINER" "$GRAFANA_HOME" "$src"
      docker restart "$GRAFANA_CONTAINER"
      sleep 2
      ver=$(grafana_version_in_container "$GRAFANA_CONTAINER" "$GRAFANA_HOME" || true)
      ;;
    *)
      rm -rf "$work"
      echo "ERROR: unsupported GRAFANA_MODE=${GRAFANA_MODE}" >&2
      exit 1
      ;;
  esac

  rm -rf "$work"
  echo "Grafana upgrade complete (now ${ver:-unknown})."
}

stop_influx() {
  if [ -n "${INFLUX_CONTAINER:-}" ] && container_exists "$INFLUX_CONTAINER"; then
    echo "Stopping container ${INFLUX_CONTAINER} ..."
    docker stop "$INFLUX_CONTAINER" || true
  fi
  if [ -n "${INFLUX_SERVICE:-}" ]; then
    echo "Stopping systemd ${INFLUX_SERVICE} ..."
    systemctl stop "$INFLUX_SERVICE" || true
  elif [ "$INFLUX_MODE" = "host-package" ]; then
    # Best-effort if service name unknown
    systemctl stop influxdb 2>/dev/null || systemctl stop influxd 2>/dev/null || true
    pkill -x influxd 2>/dev/null || true
  fi
}

start_influx() {
  if [ -n "${INFLUX_SERVICE:-}" ]; then
    systemctl start "$INFLUX_SERVICE"
  elif [ -n "${INFLUX_CONTAINER:-}" ] && container_exists "$INFLUX_CONTAINER"; then
    docker start "$INFLUX_CONTAINER"
  elif [ "$INFLUX_MODE" = "host-package" ]; then
    systemctl start influxdb 2>/dev/null || systemctl start influxd 2>/dev/null \
      || ( [ -n "$INFLUX_CONFIG" ] && "$INFLUX_BIN" -config "$INFLUX_CONFIG" & ) \
      || true
  fi
}

upgrade_influx() {
  echo "=== Upgrading InfluxDB (${INFLUX_MODE}) → ${INFLUXDB_VERSION} ==="
  local work src ver=""
  work=$(mktemp -d)
  src=$(download_influx_extract "$work")

  stop_influx

  case "$INFLUX_MODE" in
    host-tree)
      cp -a "${src}/influxd" "${src}/influx" "${src}/influx_inspect" "${INFLUX_HOME}/"
      ;;
    host-package)
      # Replace package binaries in place; keep /etc/influxdb/influxdb.conf.
      cp -a "${src}/influxd" /usr/bin/influxd
      cp -a "${src}/influx" /usr/bin/influx 2>/dev/null || true
      cp -a "${src}/influx_inspect" /usr/bin/influx_inspect 2>/dev/null || true
      INFLUX_BIN=/usr/bin/influxd
      ;;
    container)
      docker start "$INFLUX_CONTAINER" 2>/dev/null || true
      sleep 1
      docker cp "${src}/influxd" "${INFLUX_CONTAINER}:${INFLUX_BIN}"
      if [ -n "${INFLUX_HOME:-}" ]; then
        docker cp "${src}/influx" "${INFLUX_CONTAINER}:${INFLUX_HOME}/influx" 2>/dev/null || true
        docker cp "${src}/influx_inspect" "${INFLUX_CONTAINER}:${INFLUX_HOME}/influx_inspect" 2>/dev/null || true
      fi
      docker stop "$INFLUX_CONTAINER" || true
      ;;
    *)
      rm -rf "$work"
      echo "ERROR: unsupported INFLUX_MODE=${INFLUX_MODE}" >&2
      exit 1
      ;;
  esac

  rm -rf "$work"
  start_influx
  case "$INFLUX_MODE" in
    host-tree|host-package) ver=$(influx_version_from_bin "$INFLUX_BIN" || true) ;;
    container) ver=$(extract_version "$(docker exec "$INFLUX_CONTAINER" "$INFLUX_BIN" version 2>/dev/null || true)") ;;
  esac
  echo "InfluxDB upgrade complete (now ${ver:-unknown})."
}

run_verify() {
  echo "=== Monitoring layout verify (target Grafana ${GRAFANA_VERSION}, InfluxDB ${INFLUXDB_VERSION}) ==="
  echo
  discover_influx
  echo
  discover_grafana
  echo
  echo "Validating discovered layout for target=${TARGET} ..."
  validate_discovered_for_target

  echo
  if [ "$VERIFY_ERRORS" -gt 0 ]; then
    echo "Verify FAILED with ${VERIFY_ERRORS} error(s). Profile NOT written." >&2
    exit 1
  fi
  write_profile
  echo "Verify PASSED. Run the upgrade with the same --config (or default profile path)."
  exit 0
}

if [ "$VERIFY" -eq 1 ]; then
  run_verify
fi

load_profile
assert_profile_usable

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

echo
echo "Done. Re-run --verify to refresh the profile and confirm versions."
