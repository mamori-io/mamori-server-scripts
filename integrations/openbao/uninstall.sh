#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Stop OpenBao and remove the package. Keeps /opt/openbao data unless --purge.
#
# Usage:
#   bash uninstall.sh
#   bash uninstall.sh --yes
#   bash uninstall.sh --purge --yes
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

usage() {
    cat <<EOF
Usage: $0 [--purge] [--yes] [--keep-cache]

Stop and disable openbao.service, then apt-get remove openbao.
With --purge also wipe /opt/openbao (data + TLS) and apt purge.
Removes $CACHE_DIR unless --keep-cache.
EOF
}

PURGE=0
YES=0
KEEP_CACHE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge) PURGE=1 ;;
        --yes) YES=1 ;;
        --keep-cache) KEEP_CACHE=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

[[ "$(id -u)" -eq 0 ]] || die "run uninstall.sh as root"

if [[ "$YES" -ne 1 ]]; then
    echo "This will stop openbao.service and remove the openbao package."
    if [[ "$PURGE" -eq 1 ]]; then
        echo "WARNING: --purge will delete /opt/openbao (secrets data and TLS keys)."
    else
        echo "Data under /opt/openbao will be kept."
    fi
    read -r -p "Type yes to continue: " answer
    if [[ "$answer" != "yes" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

log "Stopping openbao.service"
systemctl disable --now openbao 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive
if [[ "$PURGE" -eq 1 ]]; then
    log "Purging package and /opt/openbao"
    apt-get purge -y openbao 2>/dev/null || apt-get remove -y openbao || true
    rm -rf /opt/openbao /etc/openbao
else
    log "Removing package (keeping /opt/openbao)"
    apt-get remove -y openbao || true
fi

if [[ "$KEEP_CACHE" -ne 1 && -d "$CACHE_DIR" ]]; then
    log "Removing $CACHE_DIR"
    rm -rf "$CACHE_DIR"
fi

log "Done."
