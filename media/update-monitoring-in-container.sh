#!/bin/bash
#
# Upgrade Grafana (13.2.3) and InfluxDB (1.13.1) inside a running mamori AIO container.
# Binaries live on Docker volumes, so recreating the image alone does not upgrade them.
#
# Connected (container reaches the Mamori mirror or upstream):
#   sudo ./update-monitoring-in-container.sh
#   sudo ./update-monitoring-in-container.sh grafana
#   sudo ./update-monitoring-in-container.sh influxdb
#
# Air-gapped: build media on a connected machine, copy the .tgz, then:
#   sudo ./update-monitoring-in-container.sh --media /path/to/mamori-monitoring-....tgz
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${MAMORI_CONTAINER:-mamori}"
TARGET="both"
MEDIA_FILE=""
GRAFANA_VERSION="${GRAFANA_VERSION:-13.2.3}"
INFLUXDB_VERSION="${INFLUXDB_VERSION:-1.13.1}"
INNER_MEDIA_DIR="/tmp/mamori-monitoring-media"
GRAFANA_TGZ_INNER=""
INFLUXDB_TGZ_INNER=""

usage() {
  cat <<EOF
Usage: $0 [both|grafana|influxdb] [--media PATH]

Upgrade Grafana and InfluxDB inside the Mamori container. Named volumes keep
the old binaries across an image upgrade, so this replaces them in place.

  both|grafana|influxdb   What to upgrade (default: both)
  --media PATH           Air-gap: tarball from monitoring-get-media.sh
  --media-file PATH      Same as --media
  --media-file=PATH      Same as --media

Connected host (container must reach the download URL):
  sudo $0

Air-gapped host:
  sudo $0 --media=/path/to/mamori-monitoring-grafana-VERSION-influxdb-VERSION-linux-amd64.tgz

Container name: \$MAMORI_CONTAINER (default: mamori).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    both|all|grafana|influxdb|influx)
      TARGET="$1"
      ;;
    --media-file=*)
      MEDIA_FILE="${1#--media-file=}"
      [ -n "$MEDIA_FILE" ] || { echo "ERROR: --media-file needs a path" >&2; exit 1; }
      ;;
    --media|--media-file)
      shift
      MEDIA_FILE="${1:-}"
      [ -n "$MEDIA_FILE" ] || { echo "ERROR: --media needs a path" >&2; exit 1; }
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

manifest_get() {
  awk -F= -v k="$2" '$1==k { sub(/^[^=]*=/,""); print; exit }' "$1"
}

find_script() {
  local name="$1"
  local candidate
  for candidate in \
    "${SCRIPT_DIR}/${name}" \
    "/vagrant/docker/scripts/all-in-one/${name}" \
    "$(cd "${SCRIPT_DIR}/../../.." && pwd)/docker/scripts/all-in-one/${name}" \
    "${HOME}/mamori-cursor-docs/../docker/scripts/all-in-one/${name}"
  do
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "Container '${CONTAINER}' not found." >&2
  exit 1
fi

stage_media() {
  [ -f "$MEDIA_FILE" ] || { echo "ERROR: media file not found: $MEDIA_FILE" >&2; exit 1; }
  local work manifest mtype gver iver arch gfile ifile
  work=$(mktemp -d)
  tar xzf "$MEDIA_FILE" -C "$work"
  manifest="${work}/mamori-monitoring/MANIFEST"
  if [ ! -f "$manifest" ]; then
    echo "ERROR: media has no mamori-monitoring/MANIFEST (expected monitoring-get-media.sh output)" >&2
    rm -rf "$work"
    exit 1
  fi
  mtype=$(manifest_get "$manifest" MEDIA_TYPE)
  gver=$(manifest_get "$manifest" GRAFANA_VERSION)
  iver=$(manifest_get "$manifest" INFLUXDB_VERSION)
  arch=$(manifest_get "$manifest" ARCH)
  gfile=$(manifest_get "$manifest" GRAFANA_FILE)
  ifile=$(manifest_get "$manifest" INFLUXDB_FILE)
  if [ "$mtype" != "mamori-monitoring" ]; then
    echo "ERROR: MEDIA_TYPE is '${mtype:-missing}', expected mamori-monitoring" >&2
    rm -rf "$work"
    exit 1
  fi
  if [ "$gver" != "$GRAFANA_VERSION" ]; then
    echo "ERROR: media Grafana version '${gver:-missing}' != ${GRAFANA_VERSION}" >&2
    rm -rf "$work"
    exit 1
  fi
  if [ "$iver" != "$INFLUXDB_VERSION" ]; then
    echo "ERROR: media InfluxDB version '${iver:-missing}' != ${INFLUXDB_VERSION}" >&2
    rm -rf "$work"
    exit 1
  fi
  if [ "$arch" != "amd64" ]; then
    echo "ERROR: media ARCH is '${arch:-missing}', expected amd64" >&2
    rm -rf "$work"
    exit 1
  fi
  [ -n "$gfile" ] || gfile="grafana-enterprise-${gver}.linux-amd64.tar.gz"
  [ -n "$ifile" ] || ifile="influxdb-${iver}_linux_amd64.tar.gz"
  if [ ! -f "${work}/mamori-monitoring/${gfile}" ] || [ ! -f "${work}/mamori-monitoring/${ifile}" ]; then
    echo "ERROR: media archive is missing ${gfile} or ${ifile}" >&2
    rm -rf "$work"
    exit 1
  fi
  rm -rf "$work"

  echo "Copying media file into container '${CONTAINER}'..."
  docker exec "$CONTAINER" mkdir -p "$INNER_MEDIA_DIR"
  docker cp "$MEDIA_FILE" "${CONTAINER}:${INNER_MEDIA_DIR}/media.tgz"
  docker exec "$CONTAINER" tar xzf "${INNER_MEDIA_DIR}/media.tgz" -C "$INNER_MEDIA_DIR"
  GRAFANA_TGZ_INNER="${INNER_MEDIA_DIR}/mamori-monitoring/${gfile}"
  INFLUXDB_TGZ_INNER="${INNER_MEDIA_DIR}/mamori-monitoring/${ifile}"
  docker exec "$CONTAINER" test -f "$GRAFANA_TGZ_INNER"
  docker exec "$CONTAINER" test -f "$INFLUXDB_TGZ_INNER"
  cleanup_inner_media() {
    docker exec "$CONTAINER" rm -rf "$INNER_MEDIA_DIR" 2>/dev/null || true
  }
  trap cleanup_inner_media EXIT
}

if [ -n "$MEDIA_FILE" ]; then
  stage_media
fi

run_update() {
  local name="$1"
  local container_path="$2"
  local host_script
  if ! host_script=$(find_script "$name"); then
    echo "ERROR: could not find ${name}. Expected ${SCRIPT_DIR}/${name} or /vagrant/docker/scripts/all-in-one/${name}" >&2
    exit 1
  fi
  echo "Copying ${host_script} -> ${CONTAINER}:${container_path}"
  docker cp "$host_script" "${CONTAINER}:${container_path}"
  docker exec "$CONTAINER" chmod +x "$container_path"
  case "$name" in
    update-grafana.sh)
      if [ -n "$GRAFANA_TGZ_INNER" ]; then
        docker exec -e "GRAFANA_TGZ=${GRAFANA_TGZ_INNER}" -e "GRAFANA_VERSION=${GRAFANA_VERSION}" \
          "$CONTAINER" "$container_path"
      else
        docker exec "$CONTAINER" "$container_path"
      fi
      ;;
    update-influxdb.sh)
      if [ -n "$INFLUXDB_TGZ_INNER" ]; then
        docker exec -e "INFLUXDB_TGZ=${INFLUXDB_TGZ_INNER}" -e "INFLUXDB_VERSION=${INFLUXDB_VERSION}" \
          "$CONTAINER" "$container_path"
      else
        docker exec "$CONTAINER" "$container_path"
      fi
      ;;
    *)
      echo "ERROR: unknown installer ${name}" >&2
      exit 1
      ;;
  esac
}

case "$TARGET" in
  grafana)
    run_update update-grafana.sh /opt/mamori/grafana/update-grafana.sh
    ;;
  influxdb|influx)
    run_update update-influxdb.sh /opt/mamori/influxdb/update-influxdb.sh
    ;;
  both|all)
    run_update update-influxdb.sh /opt/mamori/influxdb/update-influxdb.sh
    run_update update-grafana.sh /opt/mamori/grafana/update-grafana.sh
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

echo "Verifying versions inside ${CONTAINER} ..."
docker exec "$CONTAINER" /opt/mamori/influxdb/influxd version || true
docker exec "$CONTAINER" /opt/mamori/grafana/bin/grafana --version 2>/dev/null || \
  docker exec "$CONTAINER" /opt/mamori/grafana/bin/grafana version 2>/dev/null || true
echo "Monitoring upgrade finished."
