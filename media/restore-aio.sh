#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Restore an all-in-one Mamori backup created by backup-aio.sh onto a target
# host that has Docker installed but Mamori not yet installed.
#
# Prefer running the generated restore.sh inside the backup directory (it is
# tailored to the volume list from the source). This script is a maintained
# equivalent that reads volumes.tsv from the backup directory.
#
# Usage:
#   bash restore-aio.sh --backup /path/to/mamori-backups
#   DOCKER=docker bash restore-aio.sh -b ./mamori-backups
#
set -euo pipefail

DOCKER="${DOCKER:-sudo docker}"
HELPER_IMAGE="${HELPER_IMAGE:-mamori-alpine-boringtun}"
BACKUP_DIR=""

usage() {
    cat <<'EOF'
Usage: restore-aio.sh --backup <dir>

Restore Mamori named volumes from a backup-aio.sh output directory.
Run on the target host after Docker is installed and before Mamori install.

Options:
  -b, --backup <dir>   Backup directory containing *.tgz and volumes.tsv
  -h, --help           Show this help

Environment:
  DOCKER         Docker CLI (default: sudo docker)
  HELPER_IMAGE   Helper image name after load (default: mamori-alpine-boringtun)

EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--backup)
            BACKUP_DIR="${2:-}"
            [[ -n "$BACKUP_DIR" ]] || { echo "Missing value for --backup" >&2; exit 1; }
            shift 2
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
done

if [[ -z "$BACKUP_DIR" ]]; then
    echo "ERROR: --backup <dir> is required" >&2
    usage >&2
    exit 1
fi

BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"
MANIFEST="$BACKUP_DIR/volumes.tsv"
IMAGE_TGZ="$BACKUP_DIR/${HELPER_IMAGE}.tgz"

if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: missing volumes.tsv in $BACKUP_DIR" >&2
    echo "If this is an older backup, run the generated restore.sh in that directory." >&2
    exit 1
fi

if [[ ! -f "$IMAGE_TGZ" ]]; then
    echo "ERROR: missing helper image archive: $IMAGE_TGZ" >&2
    exit 1
fi

echo "Mamori AIO restore"
echo "  DOCKER=$DOCKER"
echo "  backup=$BACKUP_DIR"
echo "  helper=$HELPER_IMAGE"
echo ""

echo "Loading helper image ..."
$DOCKER load < "$IMAGE_TGZ"

while IFS=$'\t' read -r vol_name vol_dest; do
    [[ -z "${vol_name:-}" ]] && continue
    archive="$BACKUP_DIR/${vol_name}.tgz"
    if [[ ! -f "$archive" ]]; then
        echo "ERROR: missing volume archive: $archive" >&2
        exit 1
    fi
    echo "Restoring volume $vol_name -> $vol_dest ..."
    $DOCKER run --rm -i \
        --volume "${vol_name}:${vol_dest}" \
        --volume "${BACKUP_DIR}:/backups" \
        "$HELPER_IMAGE" \
        sh -c "cd ${vol_dest} && tar zxvf /backups/${vol_name}.tgz"
done < "$MANIFEST"

echo ""
echo "Restore complete."
echo "Next: install Mamori on this host (media/install-*.sh)."
