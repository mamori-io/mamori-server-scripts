#!/bin/bash
#
# Upgrade Grafana (13.2.3) and InfluxDB (1.13.1) inside a running mamori AIO container.
# Binaries live on Docker volumes, so recreating the image alone does not upgrade them.
#
# Usage (on the host):
#   sudo ./update-monitoring-in-container.sh
#   sudo ./update-monitoring-in-container.sh grafana
#   sudo ./update-monitoring-in-container.sh influxdb
#

set -euo pipefail

CONTAINER="${MAMORI_CONTAINER:-mamori}"
TARGET="${1:-both}"

find_script() {
  local name="$1"
  local candidate
  for candidate in \
    "/vagrant/docker/scripts/all-in-one/${name}" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/docker/scripts/all-in-one/${name}" \
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

run_update() {
  local name="$1"
  local container_path="$2"
  local host_script
  if ! host_script=$(find_script "$name"); then
    echo "ERROR: could not find ${name} on the host. Expected under /vagrant/docker/scripts/all-in-one/" >&2
    exit 1
  fi
  echo "Copying ${host_script} -> ${CONTAINER}:${container_path}"
  docker cp "$host_script" "${CONTAINER}:${container_path}"
  docker exec "$CONTAINER" chmod +x "$container_path"
  docker exec "$CONTAINER" "$container_path"
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
    echo "Usage: $0 [both|grafana|influxdb]" >&2
    exit 1
    ;;
esac

echo "Verifying versions inside ${CONTAINER} ..."
docker exec "$CONTAINER" /opt/mamori/influxdb/influxd version || true
docker exec "$CONTAINER" /opt/mamori/grafana/bin/grafana --version 2>/dev/null || \
  docker exec "$CONTAINER" /opt/mamori/grafana/bin/grafana version 2>/dev/null || true
echo "Monitoring upgrade finished."
