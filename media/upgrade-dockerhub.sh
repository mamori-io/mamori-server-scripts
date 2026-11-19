#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Upgrades a running Mamori all-in-one deployment by pulling iomamori/mamori-all-in-one:latest from Docker Hub
# and recreating the container with preserved volumes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ensure-host-timezone.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/mamori-shm-size.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/aio-pg-version.sh"

DOCKER="${DOCKER:-sudo docker}"
CONTAINER_NAME="${CONTAINER_NAME:-mamori}"
VALIDATE_ONLY=0

usage() {
    cat <<'EOF'
Usage: upgrade-dockerhub.sh [options]

Upgrade Mamori AIO from Docker Hub (iomamori/mamori-all-in-one:latest).

Options:
  --validate           Only check that AIO Postgres major matches this bundle;
                       do not upgrade
  --shm-size <size>    Container shared memory (default: from host RAM)
  -h, --help           Show this help

Postgres major must already match the bundle (18) before upgrade. If you are
still on 14, run upgrade-aio-postgres-to-18.sh first.
EOF
}

# Pre-parse script options before shm-size helper (unknown -* would error there).
PRE_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --validate)
            VALIDATE_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            PRE_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${PRE_ARGS[@]+"${PRE_ARGS[@]}"}"

mamori_shm_size_parse_args "$@" || exit 1
if [[ ${#MAMORI_SHM_REMAINING[@]} -gt 0 ]]; then
    echo "ERROR: unexpected argument: ${MAMORI_SHM_REMAINING[*]}" >&2
    usage >&2
    exit 1
fi

if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
    aio_pg_require_bundle_major "$MAMORI_AIO_BUNDLE_PG_MAJOR"
    exit $?
fi

# Always gate: volumes must already be on the bundle Postgres major.
aio_pg_require_bundle_major "$MAMORI_AIO_BUNDLE_PG_MAJOR" || exit 1

mamori_shm_size_resolve || exit 1
echo "Container shared memory: --shm-size ${MAMORI_SHM_SIZE}"

TZ_VALUE="$(host_timezone_for_container)"

# clean up any system logs that are filling the disk
sudo journalctl --vacuum-size=10M

# tag the current mamori image so we can delete is later
sudo docker image tag iomamori/mamori-all-in-one mamori-old

sudo docker pull iomamori/mamori-all-in-one:latest
RC=$?
if [ $RC -ne 0 ]; then
        echo "docker load failed :("
        exit $RC
fi

NOW=`date +%s`
sudo docker stop mamori
sudo docker rename mamori mamori-$NOW

sudo docker create \
        --network host \
        --restart always \
        --privileged \
        --shm-size "$MAMORI_SHM_SIZE" \
        --log-opt max-size=10m --log-opt max-file=10 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v mamori-var:/opt/mamori/var \
        -v mamori-nginx-conf:/etc/nginx \
        -v mamori-data:/var/lib/postgresql \
        -v mamori-pg-conf:/etc/postgresql \
        -v mamori-influxdb:/opt/mamori/influxdb \
        -v mamori-influxdb-data:/var/lib/influxdb \
        -v mamori-grafana:/opt/mamori/grafana \
        -v /proc:/host/proc:ro \
        -e "TZ=${TZ_VALUE}" \
        --name mamori iomamori/mamori-all-in-one:latest /sbin/my_init

sudo docker start mamori

sudo docker rm mamori-$NOW
sudo docker rmi `sudo docker image ls -a | grep mamori-old | awk '{print $3}'`
