#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Validate that the host firewall matches the Mamori profile in
# .mamori-firewall.env (or flags / environment).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/firewall-common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/firewall-ufw.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/firewall-firewalld.sh"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"
FAILS=0
WARNS=0

usage() {
    cat <<'EOF'
Usage: validate-firewall.sh [options]

Verify the host firewall is active and allows ports from the Mamori profile
(.mamori-firewall.env or flags).

Options:
  --wireguard / --wg-cidr / --db-proxies / --rdp / --web-proxy
  --internet-exposed / --db-public / --rdp-public / --web-public
                         Override profile for this check (same as setup-firewall.sh)
  -h, --help             Show this help
EOF
}

USED_FLAGS=0
FLAG_WIREGUARD=0
FLAG_DB=0
FLAG_RDP=0
FLAG_WEB=0
FLAG_INTERNET=0
FLAG_DB_PUBLIC=0
FLAG_RDP_PUBLIC=0
FLAG_WEB_PUBLIC=0
FLAG_WG_CIDR=""
SET_INTERNET=0
SET_DB_PUBLIC=0
SET_RDP_PUBLIC=0
SET_WEB_PUBLIC=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wireguard) FLAG_WIREGUARD=1; USED_FLAGS=1 ;;
        --wg-cidr)
            shift
            FLAG_WG_CIDR="${1:-}"
            [[ -n "$FLAG_WG_CIDR" ]] || { echo "Missing value for --wg-cidr" >&2; exit 1; }
            USED_FLAGS=1
            ;;
        --db-proxies) FLAG_DB=1; USED_FLAGS=1 ;;
        --internet-exposed) FLAG_INTERNET=1; SET_INTERNET=1; USED_FLAGS=1 ;;
        --db-public) FLAG_DB_PUBLIC=1; SET_DB_PUBLIC=1; USED_FLAGS=1 ;;
        --rdp-public) FLAG_RDP_PUBLIC=1; SET_RDP_PUBLIC=1; USED_FLAGS=1 ;;
        --web-public) FLAG_WEB_PUBLIC=1; SET_WEB_PUBLIC=1; USED_FLAGS=1 ;;
        --rdp) FLAG_RDP=1; USED_FLAGS=1 ;;
        --web-proxy) FLAG_WEB=1; USED_FLAGS=1 ;;
        -h|--help) usage; exit 0 ;;
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
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
info() { echo -e "       $*"; }

mamori_fw_load_env

if [[ "$USED_FLAGS" -eq 1 ]]; then
    MAMORI_FW_WIREGUARD="$FLAG_WIREGUARD"
    MAMORI_FW_DB_PROXIES="$FLAG_DB"
    MAMORI_FW_RDP="$FLAG_RDP"
    MAMORI_FW_WEB_PROXY="$FLAG_WEB"
    [[ -n "$FLAG_WG_CIDR" ]] && MAMORI_FW_WG_CIDR="$FLAG_WG_CIDR"
    if [[ "$SET_INTERNET" -eq 1 ]]; then
        MAMORI_FW_INTERNET_EXPOSED="$FLAG_INTERNET"
    fi
    if [[ "$SET_DB_PUBLIC" -eq 1 ]]; then
        MAMORI_FW_DB_PUBLIC="$FLAG_DB_PUBLIC"
    fi
    if [[ "$SET_RDP_PUBLIC" -eq 1 ]]; then
        MAMORI_FW_RDP_PUBLIC="$FLAG_RDP_PUBLIC"
    fi
    if [[ "$SET_WEB_PUBLIC" -eq 1 ]]; then
        MAMORI_FW_WEB_PUBLIC="$FLAG_WEB_PUBLIC"
    fi
fi

if [[ -z "${MAMORI_FW_BACKEND:-}" ]]; then
    MAMORI_FW_BACKEND="$(mamori_fw_detect_backend || true)"
fi
if [[ -z "${MAMORI_FW_BACKEND:-}" ]]; then
    echo "ERROR: could not detect firewall backend" >&2
    exit 1
fi

echo ""
echo "===================================================="
echo " Mamori – Host Firewall Validation"
echo "===================================================="
mamori_fw_print_profile
echo ""

echo "--- Backend ---"
case "$MAMORI_FW_BACKEND" in
    ufw)
        if mamori_fw_ufw_is_active; then
            pass "ufw is active"
        else
            fail "ufw is not active (run setup-firewall.sh)"
        fi
        has_port=mamori_fw_ufw_has_port
        has_cidr=mamori_fw_ufw_has_from_cidr
        ;;
    firewalld)
        if mamori_fw_firewalld_is_active; then
            pass "firewalld is running"
        else
            fail "firewalld is not running (run setup-firewall.sh)"
        fi
        has_port=mamori_fw_firewalld_has_port
        has_cidr=mamori_fw_firewalld_has_from_cidr
        ;;
    *)
        fail "Unknown backend $MAMORI_FW_BACKEND"
        has_port=true
        has_cidr=true
        ;;
esac
echo ""

echo "--- Expected allows ---"
while IFS='|' read -r proto port comment; do
    [[ -n "$port" ]] || continue
    if $has_port "$proto" "$port"; then
        pass "${proto^^}/$port allowed ($comment)"
    else
        fail "${proto^^}/$port not allowed ($comment)"
    fi
done < <(mamori_fw_expected_validate_port_rules)

if [[ "${MAMORI_FW_WIREGUARD}" == "1" ]]; then
    if $has_cidr "${MAMORI_FW_WG_CIDR}"; then
        pass "WireGuard client network ${MAMORI_FW_WG_CIDR} allowed (all ports from clients)"
    else
        fail "WireGuard client network ${MAMORI_FW_WG_CIDR} not found in firewall rules"
        info "Expected: allow from ${MAMORI_FW_WG_CIDR} (ufw) or rich-rule source accept (firewalld)"
    fi
    # Clarify optionals covered by WG when not opened publicly
    if [[ "${MAMORI_FW_DB_PROXIES}" == "1" && "${MAMORI_FW_DB_PUBLIC}" != "1" ]]; then
        info "DB proxy ports not required publicly (WireGuard CIDR covers them; db_public=0)"
    fi
    if [[ "${MAMORI_FW_RDP}" == "1" && "${MAMORI_FW_RDP_PUBLIC}" != "1" ]]; then
        info "RDP/4822 not required publicly (WireGuard CIDR covers it; rdp_public=0)"
    fi
    if [[ "${MAMORI_FW_WEB_PROXY}" == "1" && "${MAMORI_FW_WEB_PUBLIC}" != "1" ]]; then
        info "WEB/8089 not required publicly (WireGuard CIDR covers it; web_public=0)"
    fi
fi
echo ""

echo "===================================================="
if [[ "$FAILS" -eq 0 ]]; then
    echo -e "${GREEN}RESULT: READY${RESET} — firewall matches Mamori profile (${WARNS} warning(s))"
    echo "===================================================="
    echo ""
    exit 0
else
    echo -e "${RED}RESULT: NOT READY${RESET} — ${FAILS} failure(s), ${WARNS} warning(s)"
    echo "Re-run: bash setup-firewall.sh"
    echo "===================================================="
    echo ""
    exit 1
fi
