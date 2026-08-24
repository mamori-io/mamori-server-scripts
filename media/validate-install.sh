#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Pre-flight validation for a standard (all-in-one) Mamori install.
# Checks Docker, timezone (/etc/timezone), swap (optional), and ensures
# MAMORI_ROOT_PASSWORD when mamori-var needs portal root bootstrap.
#
# Timezone and swap can be configured interactively when missing, or via flags.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

FAILS=0
WARNS=0

DOCKER="${DOCKER:-docker}"
export DOCKER

usage() {
    cat <<'EOF'
Usage: validate-install.sh [options]

Validate that this host is ready for a Mamori all-in-one install.

Checks:
  - Docker available
  - Timezone (/etc/timezone set; offer to configure if missing)
  - Swap (optional; offer to create 4GB /swapfile if missing)
  - Portal root password (MAMORI_ROOT_PASSWORD) when mamori-var needs bootstrap

Options:
  --set-timezone <Zone>  Set timezone now (e.g. Australia/Melbourne); writes /etc/timezone
  --add-swap             Create 4GB /swapfile if no swap is active
  --no-prompt            Check only; do not offer interactive timezone/swap setup
  -h, --help             Show this help

Environment:
  DOCKER                 Docker/Podman CLI (default: docker)
  MAMORI_ROOT_PASSWORD   Portal root password for first boot (prompted if required)
  HOST_SWAP_SIZE_GB      Swap size when creating (default: 4)
  HOST_SWAP_FILE         Swapfile path (default: /swapfile)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --set-timezone)
            shift
            HOST_TIMEZONE_FORCE="${1:-}"
            [[ -n "$HOST_TIMEZONE_FORCE" ]] || { echo "Missing value for --set-timezone" >&2; exit 1; }
            export HOST_TIMEZONE_FORCE
            ;;
        --add-swap)
            export HOST_SWAP_FORCE=1
            ;;
        --no-prompt)
            export HOST_TIMEZONE_NOPROMPT=1
            export HOST_SWAP_NOPROMPT=1
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

pass() { echo -e "${GREEN}[PASS]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; FAILS=$((FAILS + 1)); }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; WARNS=$((WARNS + 1)); }
info() { echo -e "       $*"; }

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ensure-host-timezone.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ensure-host-swap.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ensure-mamori-root-password.sh"

echo ""
echo "===================================================="
echo " Mamori – All-in-One Install Validation"
echo " Host: $(hostname)  Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "===================================================="
echo ""

# ---------- docker ----------
echo "--- Docker ---"
if ! command -v "${DOCKER%% *}" >/dev/null 2>&1 && ! $DOCKER version >/dev/null 2>&1; then
    fail "Docker not available (DOCKER='$DOCKER')"
else
    pass "Docker available ($DOCKER)"
    if $DOCKER info >/dev/null 2>&1; then
        pass "Docker daemon is reachable"
    else
        warn "Docker binary present but daemon not reachable (start docker before install)"
    fi
fi
echo ""

# ---------- timezone ----------
echo "--- Timezone ---"
if ensure_host_timezone; then
    pass "/etc/timezone is set to ${HOST_TIMEZONE:-$(tr -d '[:space:]' </etc/timezone 2>/dev/null)}"
    TZ_CTL=""
    if command -v timedatectl >/dev/null 2>&1; then
        TZ_CTL="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    fi
    if [[ -n "$TZ_CTL" ]]; then
        info "timedatectl Timezone: $TZ_CTL"
    fi
else
    fail "/etc/timezone is missing or empty (required for container TZ). Use --set-timezone Region/City"
fi
echo ""

# ---------- swap ----------
echo "--- Swap ---"
set +e
ensure_host_swap
SWAP_RC=$?
set -e
if [[ $SWAP_RC -ne 0 ]]; then
    fail "Swap setup failed (see messages above). Retry with --add-swap or configure manually."
elif [[ "${HOST_SWAP_ACTIVE:-0}" == "1" ]]; then
    pass "Swap is active"
else
    warn "No active swap (optional — some providers disallow it). Re-run with --add-swap when allowed."
fi
echo ""

# ---------- portal root password ----------
echo "--- Portal root password ---"
if ensure_mamori_root_password; then
    if [[ "${MAMORI_ROOT_PASSWORD_REQUIRED:-0}" == "1" ]]; then
        pass "MAMORI_ROOT_PASSWORD ready for first-boot bootstrap"
    else
        pass "Portal root password already configured on mamori-var (bootstrap not required)"
    fi
else
    fail "Could not ensure MAMORI_ROOT_PASSWORD (required for fresh mamori-var)"
fi
echo ""

# ---------- summary ----------
echo "===================================================="
if [[ "$FAILS" -eq 0 ]]; then
    echo -e "${GREEN}RESULT: READY${RESET} — all hard checks passed (${WARNS} warning(s))"
    echo "===================================================="
    echo ""
    if [[ "${MAMORI_ROOT_PASSWORD_REQUIRED:-0}" == "1" ]]; then
        echo "Next: run an install script (install-dockehub.sh / install-file.sh / install-redhar-dockerhub.sh);"
        echo "      it will pass MAMORI_ROOT_PASSWORD for first boot only."
    else
        echo "Next: run an install/upgrade script (existing portal root password will be reused)."
    fi
    echo ""
    exit 0
else
    echo -e "${RED}RESULT: NOT READY${RESET} — ${FAILS} failure(s), ${WARNS} warning(s)"
    echo "Fix the FAIL items before installing."
    echo "===================================================="
    echo ""
    exit 1
fi
