#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Instantiate Presidio analyzer (:5002) and anonymizer (:5001) from the
# published docker-save archive. Does not build the image.
#
# Usage:
#   bash install.sh
#   bash install.sh /path/to/mamori-presidio-en-th-20261023.tgz
#   bash install.sh --force
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

usage() {
    cat <<EOF
Usage: $0 [--force] [archive.tgz]

Download (if needed) and load
  $ARCHIVE_URL
then create and start $ANALYZER_NAME and $ANONYMIZER_NAME.

  --force   Replace existing containers
EOF
}

FORCE=0
ARCHIVE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1 ;;
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

if container_exists "$ANALYZER_NAME" || container_exists "$ANONYMIZER_NAME"; then
    if [[ "$FORCE" -ne 1 ]]; then
        echo "Presidio containers already exist. Use --force or run upgrade.sh / uninstall.sh." >&2
        print_status
        exit 1
    fi
    echo "Removing existing containers (--force)..."
    $DOCKER rm -f "$ANALYZER_NAME" "$ANONYMIZER_NAME" 2>/dev/null || true
fi

ARCHIVE="$(ensure_archive "$ARCHIVE")"
load_archive "$ARCHIVE"

create_analyzer
create_anonymizer
$DOCKER start "$ANALYZER_NAME" "$ANONYMIZER_NAME"
print_status
