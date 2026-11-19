#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Install OpenBao from the official GitHub .deb and start the systemd service.
# Does not initialize or unseal — run bao operator init once, save state, then
# bootstrap-mamori.sh.
#
# Usage:
#   bash install.sh
#   OPENBAO_VERSION=2.7.2 bash install.sh
#   bash install.sh --force
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

usage() {
    cat <<EOF
Usage: $0 [--force]

Install OpenBao ${OPENBAO_VERSION} (${OPENBAO_ARCH}) from GitHub releases,
enable and start openbao.service.

  --force   Reinstall even if openbao is already present

Environment:
  OPENBAO_VERSION   default ${OPENBAO_VERSION}
  OPENBAO_ARCH      default ${OPENBAO_ARCH}
  OPENBAO_DEB_URL   override package URL
EOF
}

FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

require_cmd curl sha256sum awk

detect_debian_family || die "install.sh supports Debian/Ubuntu only (use the OpenBao package for your distro)"

if openbao_installed && [[ "$FORCE" -ne 1 ]]; then
    log "OpenBao already installed: $(bao version 2>/dev/null | head -1 || echo present)"
    log "Use --force to reinstall, or run bootstrap-mamori.sh"
    systemctl status openbao --no-pager 2>/dev/null | head -12 || true
    exit 0
fi

[[ "$(id -u)" -eq 0 ]] || die "run install.sh as root"

mkdir -p "$CACHE_DIR"
DEB="$CACHE_DIR/openbao_${OPENBAO_VERSION}_${OPENBAO_ARCH}.deb"
SUMS="$CACHE_DIR/checksums_${OPENBAO_VERSION}.txt"

log "Downloading $OPENBAO_DEB_URL"
curl -fL --retry 3 -o "${DEB}.tmp" "$OPENBAO_DEB_URL"
mv "${DEB}.tmp" "$DEB"

log "Downloading checksums"
curl -fL --retry 3 -o "${SUMS}.tmp" "$OPENBAO_CHECKSUMS_URL"
mv "${SUMS}.tmp" "$SUMS"

log "Verifying checksum"
(
    cd "$CACHE_DIR"
    # checksums.txt lists basename only
    awk -v f="$(basename "$DEB")" '$2 == f {print}' "$(basename "$SUMS")" | sha256sum -c -
)

export DEBIAN_FRONTEND=noninteractive
log "Installing $(basename "$DEB")"
apt-get install -y "$DEB"

log "Enabling and starting openbao.service"
systemctl enable --now openbao

log "Installed: $(bao version | head -1)"
systemctl --no-pager --full status openbao | head -20 || true
echo
echo "Next:"
echo "  1. bao operator init   # save keys + root_token to a state JSON file"
echo "  2. bao operator unseal # once per start if sealed"
echo "  3. bash bootstrap-mamori.sh --addr https://HOST:8200 --state /path/to/state.json"
