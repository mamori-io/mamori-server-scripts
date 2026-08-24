#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Pre-flight validation for a new Mamori app node (HA join or fresh install).
# Checks ports, disk, Docker, hostname, timezone (/etc/timezone), and swap per
# https://doc.mamori.io/050-installation/install
#
# Run on the new node host. Exit 0 only if all hard checks pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_FILE=""
FAILS=0
WARNS=0

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

MIN_ROOT_GB=10
REC_ROOT_GB=50
MIN_VAR_AVAIL_GB=15
MIN_DOCKER_MAJOR=26
MIN_RAM_GB=2
REC_RAM_GB=8

usage() {
    cat <<'EOF'
Usage: validate-new-node.sh [options]

Validate that this host is ready for a Mamori install / HA app-node join.

Checks:
  - Ports (via server/server-port-check.sh)
  - Disk space (root total: fail < 10GB, warn < 50GB; /var available >= 15GB)
  - Docker (>= 26, not Snap)
  - Hostname resolution (getent hosts)
  - Timezone (/etc/timezone set and matches timedatectl)
  - Swap (optional warning if missing — some providers disallow it)
  - Portal root password (MAMORI_ROOT_PASSWORD) when mamori-var needs bootstrap

Options:
  -o, --output <file>   Also write the full report to this file
  -h, --help            Show this help

Environment:
  PORT_CHECK_SCRIPT     Override path to server-port-check.sh
  DOCKER                Docker CLI (default: docker)
  MAMORI_ROOT_PASSWORD  Portal root password for first boot (prompted if required)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            shift
            REPORT_FILE="${1:-}"
            [[ -n "$REPORT_FILE" ]] || { echo "Missing value for --output" >&2; exit 1; }
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

bytes_to_gb() {
    # integer GB from 1K-block count (df default)
    local kb="$1"
    echo $((kb / 1024 / 1024))
}

# --- collect output optionally to report file ---
if [[ -n "$REPORT_FILE" ]]; then
    exec > >(tee "$REPORT_FILE") 2>&1
fi

echo ""
echo "===================================================="
echo " Mamori – New Node Pre-Flight Validation"
echo " Host: $(hostname)  Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "===================================================="
echo ""

# ---------- informational ----------
echo "--- System info ---"
ARCH="$(uname -m 2>/dev/null || echo unknown)"
info "Arch: $ARCH"

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

# ---------- timezone (install docs: /etc/timezone must be set) ----------
echo "--- Timezone ---"
TZ_FILE=""
if [[ -f /etc/timezone ]]; then
    TZ_FILE="$(tr -d '[:space:]' < /etc/timezone)"
fi
TZ_CTL=""
if command -v timedatectl >/dev/null 2>&1; then
    TZ_CTL="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    if [[ -z "$TZ_CTL" ]]; then
        TZ_CTL="$(timedatectl 2>/dev/null | awk '/Time zone:/ {print $3}')"
    fi
fi

if [[ -z "$TZ_FILE" ]]; then
    fail "/etc/timezone is missing or empty (install docs require: echo 'Region/City' > /etc/timezone)"
else
    pass "/etc/timezone is set to $TZ_FILE"
fi

if [[ -n "$TZ_CTL" ]]; then
    info "timedatectl Timezone: $TZ_CTL"
    if [[ -n "$TZ_FILE" && "$TZ_FILE" != "$TZ_CTL" ]]; then
        warn "/etc/timezone ($TZ_FILE) does not match timedatectl ($TZ_CTL) — run timedatectl set-timezone and rewrite /etc/timezone"
    elif [[ -n "$TZ_FILE" && "$TZ_FILE" == "$TZ_CTL" ]]; then
        pass "timedatectl matches /etc/timezone"
    fi
else
    warn "timedatectl not available; could not cross-check timezone"
fi
echo ""

# ---------- ports ----------
echo "--- Ports ---"
PORT_CHECK=""
if PORT_CHECK="$(resolve_port_check)"; then
    info "Using port check: $PORT_CHECK"
    PORT_OUT="$(mktemp)"
    # Port-check writes CSV into cwd and does not use set -e exit codes for occupied ports.
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
    fail "server-port-check.sh not found (expected ../server/server-port-check.sh or ./server-port-check.sh). Set PORT_CHECK_SCRIPT."
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

# ---------- docker ----------
echo "--- Docker ---"
if ! command -v docker >/dev/null 2>&1; then
    fail "Docker is not installed (install via https://get.docker.com — do not use Snap)"
else
    DOCKER_BIN="$(command -v docker)"
    info "docker binary: $DOCKER_BIN"
    if [[ "$DOCKER_BIN" == /snap/* ]] || { command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; }; then
        fail "Docker Snap install detected — use the official Docker Engine package instead"
    else
        pass "Docker is not a Snap install"
    fi

    DOCKER_VER_STR="$(docker --version 2>/dev/null || true)"
    info "$DOCKER_VER_STR"
    # e.g. Docker version 26.1.0, build ...
    DOCKER_MAJOR="$(printf '%s' "$DOCKER_VER_STR" | sed -n 's/.*version \([0-9][0-9]*\)\..*/\1/p')"
    if [[ -z "$DOCKER_MAJOR" ]]; then
        fail "Could not parse Docker version"
    elif [[ "$DOCKER_MAJOR" -ge "$MIN_DOCKER_MAJOR" ]]; then
        pass "Docker major version ${DOCKER_MAJOR} >= ${MIN_DOCKER_MAJOR}"
    else
        fail "Docker major version ${DOCKER_MAJOR} < required ${MIN_DOCKER_MAJOR}"
    fi

    if docker info >/dev/null 2>&1; then
        pass "Docker daemon is reachable"
    else
        warn "Docker binary present but daemon not reachable (start docker service before install)"
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
    NS_OUT="$(nslookup "$HN" 2>&1)"
    NS_RC=$?
    set -e
    if [[ $NS_RC -eq 0 ]]; then
        pass "nslookup $HN succeeded"
        info "$(printf '%s' "$NS_OUT" | head -8 | tr '\n' ' ')"
    else
        warn "nslookup $HN failed (DNS); getent/hosts may still be enough for private cluster nodes"
    fi
else
    warn "nslookup not installed; skipped DNS check"
fi
echo ""

# ---------- swap (optional — some cloud providers disallow swap) ----------
echo "--- Swap ---"
SWAP_SHOW="$(swapon --show --noheadings 2>/dev/null || true)"
SWAP_PROC="$(awk 'NR>1 {print}' /proc/swaps 2>/dev/null || true)"
SWAP_TOTAL_KB="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"

if [[ -n "$SWAP_SHOW" || -n "$SWAP_PROC" ]] && [[ "${SWAP_TOTAL_KB:-0}" -gt 0 ]]; then
    pass "Swap is active (${SWAP_TOTAL_KB} kB)"
    [[ -n "$SWAP_SHOW" ]] && info "swapon: $SWAP_SHOW"
    [[ -n "$SWAP_PROC" ]] && info "/proc/swaps: $SWAP_PROC"
else
    warn "No active swap (optional — some providers disallow swap). Install docs recommend 4GB when allowed."
    info "If permitted: fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
    info "  echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab"
fi
echo ""

# ---------- portal root password (bootstrap) ----------
echo "--- Portal root password ---"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ensure-mamori-root-password.sh"
export DOCKER="${DOCKER:-docker}"
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
    exit 0
else
    echo -e "${RED}RESULT: NOT READY${RESET} — ${FAILS} failure(s), ${WARNS} warning(s)"
    echo "Fix the FAIL items before installing or joining the cluster."
    echo "===================================================="
    echo ""
    exit 1
fi
