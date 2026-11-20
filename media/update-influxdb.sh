#!/bin/sh
# In-place InfluxDB OSS 1.x upgrade for AIO / volume-mounted /opt/mamori/influxdb.
# Preserves /var/lib/influxdb data and Mamori influxdb.conf.
# INFLUXDB_TGZ, when set to an existing file, is extracted instead of downloading.
set -e

INFLUXDB_VERSION="${INFLUXDB_VERSION:-1.13.1}"
INFLUXDB_EXTRACT_DIR="influxdb-${INFLUXDB_VERSION}"
INFLUXDB_URL="${INFLUXDB_DOWNLOAD_URL:-https://dl.influxdata.com/influxdb/releases/v${INFLUXDB_VERSION}/influxdb-${INFLUXDB_VERSION}_linux_amd64.tar.gz}"
INFLUXDB_MIRROR="${INFLUXDB_MIRROR_URL:-https://mamori-io.sgp1.digitaloceanspaces.com/install-media/monitoring/influxdb-${INFLUXDB_VERSION}_linux_amd64.tar.gz}"
INFLUXDB_HOME="${INFLUXDB_HOME:-/opt/mamori/influxdb}"

cd "$INFLUXDB_HOME"

echo "Stopping grafana (depends on influx) and influxdb..."
sv stop grafana || true
sv stop influxdb || true

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

TGZ="$WORK/influxdb.tgz"
if [ -n "${INFLUXDB_TGZ:-}" ]; then
  if [ ! -f "$INFLUXDB_TGZ" ]; then
    echo "ERROR: INFLUXDB_TGZ not found: $INFLUXDB_TGZ" >&2
    exit 1
  fi
  echo "Using local InfluxDB tarball ${INFLUXDB_TGZ}"
  cp "$INFLUXDB_TGZ" "$TGZ"
else
  echo "Downloading InfluxDB ${INFLUXDB_VERSION} ..."
  if ! curl -fL --retry 3 --retry-delay 2 -o "$TGZ" "$INFLUXDB_MIRROR"; then
    curl -fL --retry 3 --retry-delay 2 -o "$TGZ" "$INFLUXDB_URL"
  fi
fi

tar xzf "$TGZ" -C "$WORK"
SRC="$WORK/$INFLUXDB_EXTRACT_DIR"
if [ ! -x "$SRC/influxd" ]; then
  echo "ERROR: expected ${INFLUXDB_EXTRACT_DIR}/influxd in download" >&2
  exit 1
fi

# Keep Mamori-managed influxdb.conf; replace binaries only.
cp -a "$SRC/influxd" "$SRC/influx" "$SRC/influx_inspect" "$INFLUXDB_HOME/"

echo "InfluxDB ${INFLUXDB_VERSION} binaries installed under ${INFLUXDB_HOME}"
"$INFLUXDB_HOME/influxd" version

echo "Starting influxdb and grafana..."
sv start influxdb
sv start grafana
echo "Done."
