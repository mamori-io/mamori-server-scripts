#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Installs Mamori all-in-one on Red Hat–style hosts using Podman: enables the podman socket, pulls the image,
# creates the container with host networking and data volumes, and starts it.
# Bootstraps portal root via MAMORI_ROOT_PASSWORD when required (prompts, or uses
# an already-exported value), then scrubs that env from the container.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ensure-mamori-root-password.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ensure-host-timezone.sh"

DOCKER="${DOCKER:-sudo podman}"
export DOCKER
CONTAINER_NAME="${CONTAINER_NAME:-mamori}"

# enable the podman docker socket
sudo systemctl enable --now podman.socket

ensure_mamori_root_password

# pull the mamori docker image
$DOCKER pull docker.io/iomamori/mamori-all-in-one:latest

TZ_VALUE="$(host_timezone_for_container)"

CREATE_ARGS=(
    --network host
    --restart always
    --privileged
    --log-opt max-size=10m --log-opt max-file=10
    -v /run/podman/podman.sock:/var/run/docker.sock
    -v mamori-var:/opt/mamori/var
    -v mamori-nginx-conf:/etc/nginx
    -v mamori-data:/var/lib/postgresql
    -v mamori-pg-conf:/etc/postgresql
    -v mamori-influxdb:/opt/mamori/influxdb
    -v mamori-influxdb-data:/var/lib/influxdb
    -v mamori-grafana:/opt/mamori/grafana
    -v /proc:/host/proc:ro
    -e "TZ=${TZ_VALUE}"
    --name "$CONTAINER_NAME"
)

if [[ "${MAMORI_ROOT_PASSWORD_REQUIRED:-0}" == "1" ]]; then
    CREATE_ARGS+=(-e "MAMORI_ROOT_PASSWORD=${MAMORI_ROOT_PASSWORD}")
fi

$DOCKER create "${CREATE_ARGS[@]}" iomamori/mamori-all-in-one:latest /sbin/my_init
$DOCKER start "$CONTAINER_NAME"

if [[ "${MAMORI_ROOT_PASSWORD_REQUIRED:-0}" == "1" ]]; then
    bash "$SCRIPT_DIR/../lib/scrub-mamori-root-password-env.sh" --name "$CONTAINER_NAME"
fi

unset MAMORI_ROOT_PASSWORD 2>/dev/null || true
