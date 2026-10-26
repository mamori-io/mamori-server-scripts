#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Upgrade a running Presidio stack from a new docker-save archive (default:
# the published Spaces object). Recreates analyzer and anonymizer containers
# on the same ports.
#
# Usage:
#   bash upgrade.sh
#   bash upgrade.sh /path/to/mamori-presidio-en-th-YYYYMMDD.tgz
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

usage() {
    cat <<EOF
Usage: $0 [archive.tgz]

Load a Presidio image archive and recreate $ANALYZER_NAME / $ANONYMIZER_NAME.
Default archive: $ARCHIVE_URL
EOF
}

ARCHIVE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -n "$ARCHIVE" ]]; then
                echo "Unexpected argument: $1" >&2
                usage >&2
                exit 1
            fi
            ARCHIVE="$1"
            ;;
    esac
    shift
done

if [[ -z "$ARCHIVE" ]]; then
    mkdir -p "$CACHE_DIR"
    ARCHIVE="$CACHE_DIR/$ARCHIVE_NAME"
    echo "Downloading $ARCHIVE_URL"
    curl -fL --retry 3 -o "$ARCHIVE.tmp" "$ARCHIVE_URL"
    mv "$ARCHIVE.tmp" "$ARCHIVE"
else
    ARCHIVE="$(ensure_archive "$ARCHIVE")"
fi

load_archive "$ARCHIVE"

NOW="$(date +%s)"
for name in "$ANALYZER_NAME" "$ANONYMIZER_NAME"; do
    if container_exists "$name"; then
        $DOCKER stop "$name"
        $DOCKER rename "$name" "${name}-${NOW}"
    fi
done

create_analyzer
create_anonymizer
$DOCKER start "$ANALYZER_NAME" "$ANONYMIZER_NAME"

for name in "$ANALYZER_NAME" "$ANONYMIZER_NAME"; do
    $DOCKER rm -f "${name}-${NOW}" 2>/dev/null || true
done

print_status
