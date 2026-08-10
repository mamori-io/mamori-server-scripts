#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Start an HA app-node container and scrub MAMORI_ROOT_PASSWORD from the
# container config after derby.user.root has been stored.

set -euo pipefail

DOCKER="${DOCKER:-docker}"
CONTAINER_NAME="${CONTAINER_NAME:-mamori}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: start-ha-node.sh [options]

Start the HA mamori container, then recreate it without MAMORI_ROOT_PASSWORD
once the portal root password has been persisted.

Options:
  -n, --name <name>   Container name (default: mamori)
  -h, --help          Show this help

Environment:
  DOCKER              Docker CLI (default: docker)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)
            shift
            CONTAINER_NAME="${1:-}"
            [[ -n "$CONTAINER_NAME" ]] || { echo "Missing value for --name" >&2; exit 1; }
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

export DOCKER
$DOCKER start "$CONTAINER_NAME"
bash "$SCRIPT_DIR/../lib/scrub-mamori-root-password-env.sh" --name "$CONTAINER_NAME"
