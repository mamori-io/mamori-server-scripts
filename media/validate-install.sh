#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Pre-flight validation for a standard (all-in-one) Mamori install.
# Ensures MAMORI_ROOT_PASSWORD is set when the mamori-var volume needs
# portal root bootstrap (prompts interactively if required).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ensure-mamori-root-password.sh"

DOCKER="${DOCKER:-docker}"
export DOCKER

echo "=== Mamori all-in-one install validation ==="
echo ""

if ! command -v "${DOCKER%% *}" >/dev/null 2>&1 && ! $DOCKER version >/dev/null 2>&1; then
    echo "ERROR: docker not available (DOCKER='$DOCKER')" >&2
    exit 1
fi

ensure_mamori_root_password

echo ""
echo "Validation complete."
if [[ "${MAMORI_ROOT_PASSWORD_REQUIRED:-0}" == "1" ]]; then
    echo "Next: run an install script (install-dockehub.sh / install-file.sh); it will pass MAMORI_ROOT_PASSWORD for first boot only."
else
    echo "Next: run an install/upgrade script (existing portal root password will be reused)."
fi
