#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Download Mamori HA cluster node media (mamori_cluster_docker.tgz) as documented at:
# https://doc.mamori.io/050-installation/ha-install
#
# Default channel is ga (production media). Use --channel dev for the development build.

set -euo pipefail

CHANNEL="ga"
OUT_DIR="$(pwd)"
BASE_URL="https://mamori-io.sgp1.digitaloceanspaces.com/install-media"
MEDIA_NAME="mamori_cluster_docker.tgz"
FORCE=0

usage() {
    cat <<'EOF'
Usage: get-ha-media.sh [options]

Download the Mamori HA cluster Docker image tarball (mamori_cluster_docker.tgz).

Options:
  -c, --channel <ga|dev>   Media channel (default: ga — matches install docs)
  -d, --dir <path>         Output directory (default: current directory)
  -f, --force              Overwrite existing file
  -h, --help               Show this help

Examples:
  bash get-ha-media.sh
  bash get-ha-media.sh --dir /tmp
  bash get-ha-media.sh --channel dev --dir /tmp
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--channel)
            shift
            CHANNEL="${1:-}"
            [[ -n "$CHANNEL" ]] || { echo "Missing value for --channel" >&2; exit 1; }
            ;;
        -d|--dir)
            shift
            OUT_DIR="${1:-}"
            [[ -n "$OUT_DIR" ]] || { echo "Missing value for --dir" >&2; exit 1; }
            ;;
        -f|--force)
            FORCE=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

case "$CHANNEL" in
    ga|dev) ;;
    *)
        echo "ERROR: channel must be ga or dev (got: $CHANNEL)" >&2
        exit 1
        ;;
esac

URL="${BASE_URL}/${CHANNEL}/${MEDIA_NAME}"
DEST="${OUT_DIR%/}/${MEDIA_NAME}"

mkdir -p "$OUT_DIR"

if [[ -f "$DEST" && "$FORCE" -ne 1 ]]; then
    echo "ERROR: $DEST already exists (use --force to overwrite)" >&2
    exit 1
fi

if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: need wget or curl to download media" >&2
    exit 1
fi

echo "Downloading HA cluster media"
echo "  channel: $CHANNEL"
echo "  url:     $URL"
echo "  dest:    $DEST"

TMP="$(mktemp "${OUT_DIR%/}/${MEDIA_NAME}.partial.XXXXXX")"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

if command -v wget >/dev/null 2>&1; then
    wget -O "$TMP" "$URL"
else
    curl -fL --progress-bar -o "$TMP" "$URL"
fi

# Basic sanity: non-empty and looks like a gzip/tar
SIZE="$(wc -c < "$TMP" | tr -d ' ')"
if [[ "$SIZE" -lt 1000000 ]]; then
    echo "ERROR: download looks too small (${SIZE} bytes) — check URL/channel" >&2
    exit 1
fi

mv -f "$TMP" "$DEST"
trap - EXIT

echo "Wrote $DEST (${SIZE} bytes)"
echo "Next (per HA install docs): docker load < $DEST"
