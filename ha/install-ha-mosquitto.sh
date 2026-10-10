#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Discover, verify, install, or upgrade Eclipse Mosquitto for Mamori HA.
#
# Placement:
#   Scenario A (cloud LB): run on the monitoring box
#   Scenario B (deployed gateway): run on the gateway host
#
# Flow:
#   sudo ./install-ha-mosquitto.sh --verify
#   sudo ./install-ha-mosquitto.sh --install
#   sudo ./install-ha-mosquitto.sh --upgrade   # requires prior --verify profile
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gateway-service-common.sh
source "${SCRIPT_DIR}/lib/gateway-service-common.sh"

DOCKER="${DOCKER:-docker}"
MOSQUITTO_IMAGE="${MOSQUITTO_IMAGE:-eclipse-mosquitto}"
MOSQUITTO_MIRROR_TGZ="${MOSQUITTO_MIRROR_TGZ:-https://mamori-io.sgp1.digitaloceanspaces.com/docker-images/eclipse-mosquitto.tgz}"
MOSQUITTO_CONTAINER="${MOSQUITTO_CONTAINER:-mosquitto}"
MOSQUITTO_HOME="${MOSQUITTO_HOME:-/opt/mamori/mosquitto}"
PROFILE_PATH="${MOSQUITTO_PROFILE:-${SCRIPT_DIR}/gateway-mosquitto.env}"

MODE=""
FORCE=0
VERIFY_ERRORS=0

usage() {
  cat <<EOF
Usage: $0 --verify|--install|--upgrade [options]

Install Eclipse Mosquitto (Docker, host network) for Mamori HA multi-node MQTT.

  --verify    Discover layout, validate, write profile (no mutations)
  --install   Create conf + container if missing
  --upgrade   Recreate container from image (requires prior --verify profile)

Options:
  --config PATH       Profile path (default: ${SCRIPT_DIR}/gateway-mosquitto.env)
  --name NAME         Container name (default: mosquitto)
  --home DIR          Data/conf root (default: /opt/mamori/mosquitto)
  --image IMAGE       Docker image (default: eclipse-mosquitto)
  --force             Replace existing container on --install
  -h, --help

Environment:
  DOCKER              Docker CLI (default: docker). Example: DOCKER="sudo docker"

After install, on an app node:
  docker exec -it mamori msql "call SET_SERVER_PROPERTY('mqtt_server', 'tcp://<this-host>:1883')"
  docker exec -it mamori sv restart mamori_fqod
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --verify) MODE=verify ;;
    --install) MODE=install ;;
    --upgrade) MODE=upgrade ;;
    --config)
      shift
      PROFILE_PATH="${1:-}"
      [ -n "$PROFILE_PATH" ] || { echo "ERROR: --config requires a path" >&2; exit 1; }
      ;;
    --name)
      shift
      MOSQUITTO_CONTAINER="${1:-}"
      ;;
    --home)
      shift
      MOSQUITTO_HOME="${1:-}"
      ;;
    --image)
      shift
      MOSQUITTO_IMAGE="${1:-}"
      ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

[ -n "$MODE" ] || { echo "ERROR: specify --verify, --install, or --upgrade" >&2; usage >&2; exit 1; }

require_root

MOSQUITTO_CONF="${MOSQUITTO_HOME}/mosquitto.conf"

write_mosquitto_conf() {
  mkdir -p "${MOSQUITTO_HOME}/data" "${MOSQUITTO_HOME}/log"
  if [ ! -f "$MOSQUITTO_CONF" ]; then
    cat > "$MOSQUITTO_CONF" <<'EOF'
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
bind_address 0.0.0.0
allow_anonymous true
EOF
  fi
}

pull_or_load_image() {
  if $DOCKER pull "$MOSQUITTO_IMAGE" 2>/dev/null; then
    return 0
  fi
  warn "docker pull failed; trying Spaces mirror tarball"
  local work tgz
  work=$(mktemp -d)
  tgz="${work}/eclipse-mosquitto.tgz"
  if curl -fL --retry 3 -o "$tgz" "$MOSQUITTO_MIRROR_TGZ"; then
    $DOCKER load < "$tgz"
  else
    rm -rf "$work"
    echo "ERROR: could not pull or load Mosquitto image" >&2
    exit 1
  fi
  rm -rf "$work"
}

create_and_start() {
  write_mosquitto_conf
  if container_exists "$MOSQUITTO_CONTAINER"; then
    if [ "$FORCE" -eq 1 ]; then
      $DOCKER rm -f "$MOSQUITTO_CONTAINER" >/dev/null
    else
      echo "ERROR: container '${MOSQUITTO_CONTAINER}' already exists (use --force)" >&2
      exit 1
    fi
  fi
  pull_or_load_image
  $DOCKER create --name "$MOSQUITTO_CONTAINER" --restart always --network host \
    --log-opt max-size=10m --log-opt max-file=5 \
    -v "${MOSQUITTO_CONF}:/mosquitto/config/mosquitto.conf" \
    -v "${MOSQUITTO_HOME}/data:/mosquitto/data" \
    -v "${MOSQUITTO_HOME}/log:/mosquitto/log" \
    "$MOSQUITTO_IMAGE"
  $DOCKER start "$MOSQUITTO_CONTAINER"
}

discover_and_verify() {
  echo "=== Mosquitto verify ==="
  VERIFY_ERRORS=0

  if ! command_exists docker && ! command_exists "${DOCKER%% *}"; then
    fail "docker not found"
  else
    ok "docker available (${DOCKER})"
  fi

  local image_id="" running="false" ver=""
  if container_exists "$MOSQUITTO_CONTAINER"; then
    ok "container exists: ${MOSQUITTO_CONTAINER}"
    image_id=$($DOCKER inspect -f '{{.Config.Image}}' "$MOSQUITTO_CONTAINER" 2>/dev/null || true)
    running=$($DOCKER inspect -f '{{.State.Running}}' "$MOSQUITTO_CONTAINER" 2>/dev/null || echo false)
    if [ "$running" = "true" ]; then
      ok "container running"
    else
      fail "container exists but is not running"
    fi
  else
    warn "container ${MOSQUITTO_CONTAINER} not found (ok before --install)"
  fi

  if [ -f "$MOSQUITTO_CONF" ]; then
    ok "conf present: ${MOSQUITTO_CONF}"
  else
    warn "conf missing: ${MOSQUITTO_CONF} (ok before --install)"
  fi

  if port_listening 1883; then
    ok "port 1883 listening"
  else
    warn "port 1883 not listening"
  fi

  if [ "$VERIFY_ERRORS" -gt 0 ]; then
    echo "Verify FAILED with ${VERIFY_ERRORS} error(s). Profile NOT written." >&2
    exit 1
  fi

  write_profile_file "$PROFILE_PATH" <<EOF
# Generated by install-ha-mosquitto.sh --verify
PROFILE_VERSION=1
DISCOVERED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
MOSQUITTO_CONTAINER=${MOSQUITTO_CONTAINER}
MOSQUITTO_IMAGE=${image_id:-$MOSQUITTO_IMAGE}
MOSQUITTO_HOME=${MOSQUITTO_HOME}
MOSQUITTO_CONF=${MOSQUITTO_CONF}
MOSQUITTO_RUNNING=${running}
EOF
  echo "Verify PASSED."
}

do_install() {
  echo "=== Mosquitto install ==="
  create_and_start
  sleep 1
  if port_listening 1883; then
    ok "Mosquitto listening on :1883"
  else
    warn "container started but :1883 not detected yet"
  fi
  echo "Done. Point app nodes at mqtt_server tcp://$(hostname -f 2>/dev/null || hostname):1883"
}

do_upgrade() {
  echo "=== Mosquitto upgrade ==="
  load_profile_file "$PROFILE_PATH"
  MOSQUITTO_CONTAINER="${MOSQUITTO_CONTAINER:-mosquitto}"
  MOSQUITTO_HOME="${MOSQUITTO_HOME:-/opt/mamori/mosquitto}"
  MOSQUITTO_IMAGE="${MOSQUITTO_IMAGE:-eclipse-mosquitto}"
  MOSQUITTO_CONF="${MOSQUITTO_CONF:-${MOSQUITTO_HOME}/mosquitto.conf}"

  write_mosquitto_conf
  pull_or_load_image
  if container_exists "$MOSQUITTO_CONTAINER"; then
    $DOCKER stop "$MOSQUITTO_CONTAINER" || true
    $DOCKER rm "$MOSQUITTO_CONTAINER" || true
  fi
  FORCE=1
  create_and_start
  echo "Mosquitto upgrade complete."
}

case "$MODE" in
  verify) discover_and_verify ;;
  install) do_install ;;
  upgrade) do_upgrade ;;
esac
