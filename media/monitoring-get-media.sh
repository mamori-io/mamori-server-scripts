#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Download pinned Grafana Enterprise and InfluxDB OSS tarballs into one
# archive for air-gapped monitoring upgrades. Run this on a machine with
# internet access, then copy the .tgz to the air-gapped host.
#
# Usage:
#   ./monitoring-get-media.sh
#   ./monitoring-get-media.sh --dir /tmp
#   GRAFANA_VERSION=13.2.3 INFLUXDB_VERSION=1.13.1 ./monitoring-get-media.sh --force
#
# Then on the air-gapped host:
#   sudo ./update-monitoring-in-container.sh --media=/path/to/mamori-monitoring-....tgz
#   sudo ./upgrade-shared-monitoring.sh --media=/path/to/mamori-monitoring-....tgz
#
set -euo pipefail

GRAFANA_VERSION="${GRAFANA_VERSION:-13.2.3}"
INFLUXDB_VERSION="${INFLUXDB_VERSION:-1.13.1}"
ARCH="amd64"
OUT_DIR="$(pwd)"
FORCE=0

GRAFANA_NAME="grafana-enterprise-${GRAFANA_VERSION}.linux-${ARCH}.tar.gz"
INFLUX_NAME="influxdb-${INFLUXDB_VERSION}_linux_${ARCH}.tar.gz"
GRAFANA_MIRROR_URL="${GRAFANA_MIRROR_URL:-https://mamori-io.sgp1.digitaloceanspaces.com/install-media/monitoring/${GRAFANA_NAME}}"
GRAFANA_DOWNLOAD_URL="${GRAFANA_DOWNLOAD_URL:-https://dl.grafana.com/enterprise/release/${GRAFANA_NAME}}"
INFLUXDB_MIRROR_URL="${INFLUXDB_MIRROR_URL:-https://mamori-io.sgp1.digitaloceanspaces.com/install-media/monitoring/${INFLUX_NAME}}"
INFLUXDB_DOWNLOAD_URL="${INFLUXDB_DOWNLOAD_URL:-https://dl.influxdata.com/influxdb/releases/v${INFLUXDB_VERSION}/${INFLUX_NAME}}"

usage() {
  cat <<EOF
Usage: $0 [options]

Download Grafana Enterprise ${GRAFANA_VERSION} and InfluxDB OSS ${INFLUXDB_VERSION}
(linux-${ARCH}) into one .tgz for air-gapped monitoring upgrades.

Options:
  --dir PATH     Output directory (default: current directory)
  --force        Overwrite an existing tarball
  -h, --help

Versions (env, optional):
  GRAFANA_VERSION     Default: 13.2.3
  INFLUXDB_VERSION    Default: 1.13.1

Examples:
  bash monitoring-get-media.sh
  bash monitoring-get-media.sh --dir /tmp

On the air-gapped host:
  sudo ./update-monitoring-in-container.sh --media=/path/to/mamori-monitoring-....tgz
  sudo ./upgrade-shared-monitoring.sh --media=/path/to/mamori-monitoring-....tgz
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir|-d)
      shift
      OUT_DIR="${1:-}"
      [ -n "$OUT_DIR" ] || { echo "ERROR: --dir needs a path" >&2; exit 1; }
      ;;
    --force|-f) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required to download monitoring media" >&2
  exit 1
fi

download_first_available() {
  local dest="$1"
  shift
  local url
  for url in "$@"; do
    echo "Trying ${url} ..."
    if curl -fL --retry 3 --retry-delay 2 -o "${dest}.partial" "$url"; then
      mv "${dest}.partial" "$dest"
      echo "Downloaded $(basename "$dest")"
      return 0
    fi
    rm -f "${dest}.partial"
  done
  echo "ERROR: failed to download $(basename "$dest")" >&2
  return 1
}

assert_tarball() {
  local tgz="$1" expected_top="$2" needle="$3"
  local listing top
  listing=$(tar tzf "$tgz")
  top=$(printf '%s\n' "$listing" | awk -F/ 'NR==1 { print $1; exit }')
  if [ "$top" != "$expected_top" ]; then
    echo "ERROR: $(basename "$tgz") top-level dir is '${top}', expected '${expected_top}'" >&2
    exit 1
  fi
  if ! printf '%s\n' "$listing" | grep -q "^${needle}$"; then
    echo "ERROR: $(basename "$tgz") is missing ${needle}" >&2
    exit 1
  fi
}

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ROOT="${WORK}/mamori-monitoring"
mkdir -p "$ROOT"

echo "Downloading Grafana ${GRAFANA_VERSION} ..."
download_first_available "${ROOT}/${GRAFANA_NAME}" "$GRAFANA_MIRROR_URL" "$GRAFANA_DOWNLOAD_URL"
assert_tarball "${ROOT}/${GRAFANA_NAME}" "grafana-${GRAFANA_VERSION}" "grafana-${GRAFANA_VERSION}/bin/grafana"

echo "Downloading InfluxDB ${INFLUXDB_VERSION} ..."
download_first_available "${ROOT}/${INFLUX_NAME}" "$INFLUXDB_MIRROR_URL" "$INFLUXDB_DOWNLOAD_URL"
assert_tarball "${ROOT}/${INFLUX_NAME}" "influxdb-${INFLUXDB_VERSION}" "influxdb-${INFLUXDB_VERSION}/influxd"

cat > "${ROOT}/MANIFEST" <<EOF
MEDIA_TYPE=mamori-monitoring
GRAFANA_VERSION=${GRAFANA_VERSION}
INFLUXDB_VERSION=${INFLUXDB_VERSION}
ARCH=${ARCH}
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GRAFANA_FILE=${GRAFANA_NAME}
INFLUXDB_FILE=${INFLUX_NAME}
EOF

OUT_NAME="mamori-monitoring-grafana-${GRAFANA_VERSION}-influxdb-${INFLUXDB_VERSION}-linux-${ARCH}.tgz"
mkdir -p "$OUT_DIR"
DEST="${OUT_DIR%/}/${OUT_NAME}"
if [ -f "$DEST" ] && [ "$FORCE" -ne 1 ]; then
  echo "ERROR: $DEST already exists (use --force to overwrite)" >&2
  exit 1
fi

tar czf "$DEST" -C "$WORK" mamori-monitoring
SIZE=$(wc -c < "$DEST" | tr -d ' ')
echo "Wrote $DEST (${SIZE} bytes)"
echo "  Grafana ${GRAFANA_VERSION}"
echo "  InfluxDB ${INFLUXDB_VERSION}"
echo
echo "On the air-gapped host:"
echo "  # all-in-one (from media/)"
echo "  sudo ./update-monitoring-in-container.sh --media=${DEST}"
echo "  # HA shared services (from ha/, after --verify)"
echo "  sudo ./upgrade-shared-monitoring.sh --media=${DEST}"
