#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Pre-flight validation for a standard (all-in-one) Mamori install.
# Checks ports, disk, Docker, hostname, timezone, swap, and portal root password.
# Works on Ubuntu and Red Hat–style hosts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

FAILS=0
WARNS=0

MIN_ROOT_GB=10
REC_ROOT_GB=50
MIN_VAR_AVAIL_GB=15
MIN_DOCKER_MAJOR=26
MIN_RAM_GB=2
REC_RAM_GB=8

DOCKER="${DOCKER:-docker}"
export DOCKER

LIST_TIMEZONES=0
LIST_TIMEZONES_FILTER=""

usage() {
    cat <<'EOF'
Usage: validate-install.sh [options]

Validate that this host is ready for a Mamori all-in-one install (Ubuntu or Red Hat).

Checks:
  - Ports (via server/server-port-check.sh)
  - Disk space (root total: fail < 10GB, warn < 50GB; /var available >= 15GB)
  - Docker / Podman (>= 26, not Snap when using docker)
  - Hostname resolution (getent hosts)
  - Timezone; offer to configure if missing
  - Swap (optional; offer to create 4GB /swapfile if missing)
  - Portal root password when mamori-var needs bootstrap

Options:
  --list-timezones [filter]  List IANA timezones (optional substring filter) and exit
  --set-timezone <Zone>      Set timezone now (e.g. Australia/Melbourne)
  --add-swap                 Create 4GB /swapfile if no swap is active
  --no-prompt                Check only; do not offer interactive timezone/swap setup
  -h, --help                 Show this help

Environment:
  DOCKER                 Docker/Podman CLI (default: docker; Red Hat: sudo podman)
  PORT_CHECK_SCRIPT      Override path to server-port-check.sh
  MAMORI_ROOT_PASSWORD   Portal root password for first boot (prompted if required)
  HOST_SWAP_SIZE_GB      Swap size when creating (default: 4)
  HOST_SWAP_FILE         Swapfile path (default: /swapfile)

Examples:
  bash validate-install.sh
  bash validate-install.sh --list-timezones Australia
  bash validate-install.sh --set-timezone Australia/Melbourne --add-swap
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list-timezones)
            LIST_TIMEZONES=1
            if [[ $# -ge 2 && "$2" != -* ]]; then
                shift
                LIST_TIMEZONES_FILTER="$1"
            fi
            ;;
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

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ensure-host-timezone.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ensure-host-swap.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ensure-mamori-root-password.sh"

if [[ "$LIST_TIMEZONES" -eq 1 ]]; then
    host_timezone_list "$LIST_TIMEZONES_FILTER"
    exit $?
fi

pass() { echo -e "${GREEN}[PASS]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; FAILS=$((FAILS + 1)); }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
info() { echo -e "       $*"; }

bytes_to_gb() {
    local kb="$1"
    echo $((kb / 1024 / 1024))
}

resolve_port_check() {
    if [[ -n "${PORT_CHECK_SCRIPT:-}" && -f "$PORT_CHECK_SCRIPT" ]]; then
        printf '%s' "$PORT_CHECK_SCRIPT"
        return 0
    fi
    if [[ -f "$SCRIPT_DIR/../server/server-port-check.sh" ]]; then
        printf '%s' "$SCRIPT_DIR/../server/server-port-check.sh"
        return 0
    fi
    if [[ -f "$SCRIPT_DIR/server-port-check.sh" ]]; then
        printf '%s' "$SCRIPT_DIR/server-port-check.sh"
        return 0
    fi
    return 1
}

echo ""
echo "===================================================="
echo " Mamori – All-in-One Install Validation"
echo " Host: $(hostname)  Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "===================================================="
echo ""

# ---------- system info ----------
echo "--- System info ---"
info "Arch: $(uname -m 2>/dev/null || echo unknown)"
MEM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
MEM_MB=$((MEM_KB / 1024))
MIN_RAM_MB=$((MIN_RAM_GB * 1024))
REC_RAM_MB=$((REC_RAM_GB * 1024))
if [[ "$MEM_MB" -lt "$MIN_RAM_MB" ]]; then
    warn "RAM ${MEM_MB}MB is below documented minimum (${MIN_RAM_GB}GB)"
elif [[ "$MEM_MB" -lt "$REC_RAM_MB" ]]; then
    warn "RAM ${MEM_MB}MB is below recommended (${REC_RAM_GB}GB); minimum ${MIN_RAM_GB}GB met"
else
    pass "RAM ${MEM_MB}MB"
fi
echo ""

# ---------- ports ----------
echo "--- Ports ---"
if PORT_CHECK="$(resolve_port_check)"; then
    info "Using port check: $PORT_CHECK"
    PORT_OUT="$(mktemp)"
    set +e
    bash "$PORT_CHECK" >"$PORT_OUT" 2>&1
    set -e
    cat "$PORT_OUT"
    if grep -q '\[OCCUPIED\]' "$PORT_OUT"; then
        fail "One or more required Mamori ports are occupied"
    else
        pass "All checked Mamori ports are available"
    fi
    rm -f "$PORT_OUT"
else
    fail "server-port-check.sh not found (expected ../server/server-port-check.sh). Set PORT_CHECK_SCRIPT."
fi
echo ""

# ---------- disk ----------
echo "--- Disk space ---"
ROOT_TOTAL_KB="$(df -kP / | awk 'NR==2 {print $2}')"
ROOT_AVAIL_KB="$(df -kP / | awk 'NR==2 {print $4}')"
VAR_AVAIL_KB="$(df -kP /var | awk 'NR==2 {print $4}')"
ROOT_TOTAL_GB="$(bytes_to_gb "$ROOT_TOTAL_KB")"
ROOT_AVAIL_GB="$(bytes_to_gb "$ROOT_AVAIL_KB")"
VAR_AVAIL_GB="$(bytes_to_gb "$VAR_AVAIL_KB")"

info "Root total: ${ROOT_TOTAL_GB}GB  available: ${ROOT_AVAIL_GB}GB"
info "/var available: ${VAR_AVAIL_GB}GB"

if [[ "$ROOT_TOTAL_GB" -lt "$MIN_ROOT_GB" ]]; then
    fail "Root filesystem size ${ROOT_TOTAL_GB}GB < required minimum ${MIN_ROOT_GB}GB"
elif [[ "$ROOT_TOTAL_GB" -lt "$REC_ROOT_GB" ]]; then
    warn "Root filesystem size ${ROOT_TOTAL_GB}GB is below recommended ${REC_ROOT_GB}GB (minimum ${MIN_ROOT_GB}GB met)"
else
    pass "Root filesystem size ${ROOT_TOTAL_GB}GB >= recommended ${REC_ROOT_GB}GB"
fi

if [[ "$VAR_AVAIL_GB" -ge "$MIN_VAR_AVAIL_GB" ]]; then
    pass "/var available ${VAR_AVAIL_GB}GB >= ${MIN_VAR_AVAIL_GB}GB"
else
    fail "/var available ${VAR_AVAIL_GB}GB < required ${MIN_VAR_AVAIL_GB}GB"
fi
echo ""

# ---------- docker / podman ----------
echo "--- Docker ---"
DOCKER_FIRST="${DOCKER%% *}"
# When DOCKER="sudo docker", inspect the real binary name
RUNTIME_NAME="$DOCKER_FIRST"
case "$DOCKER" in
    *podman*) RUNTIME_NAME=podman ;;
    *docker*) RUNTIME_NAME=docker ;;
esac

if ! command -v "$DOCKER_FIRST" >/dev/null 2>&1 && ! $DOCKER version >/dev/null 2>&1; then
    fail "Docker/Podman not available (DOCKER='$DOCKER')"
    info "Ubuntu: sudo curl https://get.docker.com | sh"
    info "Red Hat: install Podman, then DOCKER='sudo podman' bash validate-install.sh"
else
    pass "Container runtime available ($DOCKER)"

    if [[ "$RUNTIME_NAME" == "docker" ]]; then
        DOCKER_BIN="$(command -v docker 2>/dev/null || true)"
        [[ -n "$DOCKER_BIN" ]] && info "binary: $DOCKER_BIN"
        if [[ -n "$DOCKER_BIN" && "$DOCKER_BIN" == /snap/* ]] || { command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; }; then
            fail "Docker Snap install detected — use the official Docker Engine package instead"
        else
            pass "Docker is not a Snap install"
        fi

        DOCKER_VER_STR="$($DOCKER --version 2>/dev/null || true)"
        info "$DOCKER_VER_STR"
        DOCKER_MAJOR="$(printf '%s' "$DOCKER_VER_STR" | sed -n 's/.*version \([0-9][0-9]*\)\..*/\1/p')"
        if [[ -z "$DOCKER_MAJOR" ]]; then
            fail "Could not parse Docker version"
        elif [[ "$DOCKER_MAJOR" -ge "$MIN_DOCKER_MAJOR" ]]; then
            pass "Docker major version ${DOCKER_MAJOR} >= ${MIN_DOCKER_MAJOR}"
        else
            fail "Docker major version ${DOCKER_MAJOR} < required ${MIN_DOCKER_MAJOR}"
        fi
    else
        DOCKER_VER_STR="$($DOCKER --version 2>/dev/null || true)"
        info "$DOCKER_VER_STR"
        pass "Using Podman"
    fi

    if $DOCKER info >/dev/null 2>&1; then
        pass "Daemon is reachable"
    else
        warn "Binary present but daemon not reachable (start docker/podman before install)"
    fi
fi
echo ""

# ---------- hostname ----------
echo "--- Hostname resolution ---"
HN="$(hostname)"
info "hostname: $HN"
GETENT_OUT="$(getent hosts "$HN" 2>/dev/null || true)"
if [[ -n "$GETENT_OUT" ]]; then
    pass "getent hosts $HN -> $GETENT_OUT"
else
    fail "hostname '$HN' does not resolve via getent hosts (add to /etc/hosts or DNS)"
fi
if command -v nslookup >/dev/null 2>&1; then
    set +e
    nslookup "$HN" >/dev/null 2>&1
    NS_RC=$?
    set -e
    if [[ $NS_RC -eq 0 ]]; then
        pass "nslookup $HN succeeded"
    else
        warn "nslookup $HN failed (DNS); getent/hosts may still be enough"
    fi
else
    info "nslookup not installed; skipped DNS check"
fi
echo ""

# ---------- timezone ----------
echo "--- Timezone ---"
if ensure_host_timezone; then
    pass "Host timezone ready for containers: ${HOST_TIMEZONE:-$(host_timezone_for_container)}"
else
    fail "Timezone not configured. Use --list-timezones and --set-timezone Region/City"
fi
echo ""

# ---------- swap ----------
echo "--- Swap ---"
set +e
ensure_host_swap
SWAP_RC=$?
set -e
if [[ $SWAP_RC -ne 0 ]]; then
    fail "Swap setup failed (see messages above). Retry with --add-swap"
elif [[ "${HOST_SWAP_ACTIVE:-0}" == "1" ]]; then
    pass "Swap is active"
else
    warn "No active swap (optional). Re-run with --add-swap when the provider allows it."
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
        echo "Next: bash install-dockehub.sh   # or install-file.sh / install-redhat-dockerhub.sh"
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
