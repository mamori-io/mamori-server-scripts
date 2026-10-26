#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Remove Presidio analyzer and anonymizer containers. Optionally keep images
# and the downloaded archive.
#
# Usage:
#   bash uninstall.sh
#   bash uninstall.sh --yes
#   bash uninstall.sh --keep-images
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

usage() {
    cat <<EOF
Usage: $0 [--keep-images] [--keep-cache] [--yes]

Stop and remove $ANALYZER_NAME and $ANONYMIZER_NAME.
Removes $ANALYZER_IMAGE and $ANONYMIZER_IMAGE unless --keep-images.
Removes $CACHE_DIR unless --keep-cache.
EOF
}

KEEP_IMAGES=0
KEEP_CACHE=0
YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-images) KEEP_IMAGES=1 ;;
        --keep-cache) KEEP_CACHE=1 ;;
        --yes) YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if [[ "$YES" -ne 1 ]]; then
    echo "This will stop and remove $ANALYZER_NAME and $ANONYMIZER_NAME."
    if [[ "$KEEP_IMAGES" -ne 1 ]]; then
        echo "Images $ANALYZER_IMAGE and $ANONYMIZER_IMAGE will be removed."
    fi
    read -r -p "Type yes to continue: " answer
    if [[ "$answer" != "yes" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

echo "Removing containers..."
$DOCKER rm -f "$ANALYZER_NAME" "$ANONYMIZER_NAME" 2>/dev/null || true
while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    echo "  Removing leftover: $name"
    $DOCKER rm -f "$name" 2>/dev/null || true
done < <($DOCKER ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^(${ANALYZER_NAME}|${ANONYMIZER_NAME})-[0-9]+$" || true)

if [[ "$KEEP_IMAGES" -ne 1 ]]; then
    echo "Removing images..."
    $DOCKER rmi "$ANALYZER_IMAGE" 2>/dev/null || true
    $DOCKER rmi "$ANONYMIZER_IMAGE" 2>/dev/null || true
fi

if [[ "$KEEP_CACHE" -ne 1 && -d "$CACHE_DIR" ]]; then
    echo "Removing $CACHE_DIR"
    rm -rf "$CACHE_DIR"
fi

echo "Done."
