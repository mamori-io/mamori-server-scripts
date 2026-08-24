#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Configure the host firewall for a Mamori all-in-one server (Ubuntu ufw or
# Red Hat firewalld). Prompts for WireGuard, DB proxies, RDP, and WEB proxy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/firewall-common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/firewall-ufw.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/firewall-firewalld.sh"

NO_PROMPT=0
FLAG_WIREGUARD=0
FLAG_DB=0
FLAG_RDP=0
FLAG_WEB=0
FLAG_INTERNET=0
FLAG_DB_PUBLIC=0
FLAG_RDP_PUBLIC=0
FLAG_WEB_PUBLIC=0
FLAG_WG_CIDR=""
USED_FLAGS=0
SET_INTERNET=0
SET_DB_PUBLIC=0
SET_RDP_PUBLIC=0
SET_WEB_PUBLIC=0

usage() {
    cat <<'EOF'
Usage: setup-firewall.sh [options]

Configure the host firewall for Mamori (Ubuntu: ufw, Red Hat: firewalld).

Always opens: TCP 22 (SSH), TCP 443 (HTTPS).

Interactive prompts (default) ask whether to enable:
  - WireGuard (UDP 51871 + client CIDR, default 172.0.0.0/16)
    WireGuard clients on that CIDR may reach all host ports (DB, RDP 4822,
    WEB proxy 8089, …) without opening those ports publicly.
  - Whether the host is internet-exposed
  - DB proxies / RDP / WEB proxy — opens ports to any source; on an
    internet-exposed host each requires an extra confirm (default N)

Options:
  --wireguard              Enable WireGuard rules
  --wg-cidr <CIDR>         WireGuard client network (default: 172.0.0.0/16)
  --db-proxies             Enable DB / SSH proxy ports (any source)
  --rdp                    Enable RDP (guacd TCP 4822, any source)
  --web-proxy              Enable HTTP/S proxy (TCP 8089, any source)
  --internet-exposed       Record that this host is internet-facing
  --db-public              Allow --db-proxies on an internet-exposed host
  --rdp-public             Allow --rdp on an internet-exposed host
  --web-public             Allow --web-proxy on an internet-exposed host
  --no-prompt              Do not prompt; use flags/env/.mamori-firewall.env only
  -h, --help               Show this help

Profile is saved to .mamori-firewall.env for validate-firewall.sh.

Non-interactive: on an internet-exposed host, --db-proxies / --rdp /
--web-proxy each require the matching --*-public flag (prefer WireGuard).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wireguard)
            FLAG_WIREGUARD=1
            USED_FLAGS=1
            ;;
        --wg-cidr)
            shift
            FLAG_WG_CIDR="${1:-}"
            [[ -n "$FLAG_WG_CIDR" ]] || { echo "Missing value for --wg-cidr" >&2; exit 1; }
            USED_FLAGS=1
            ;;
        --db-proxies)
            FLAG_DB=1
            USED_FLAGS=1
            ;;
        --internet-exposed)
            FLAG_INTERNET=1
            SET_INTERNET=1
            USED_FLAGS=1
            ;;
        --db-public)
            FLAG_DB_PUBLIC=1
            SET_DB_PUBLIC=1
            USED_FLAGS=1
            ;;
        --rdp-public)
            FLAG_RDP_PUBLIC=1
            SET_RDP_PUBLIC=1
            USED_FLAGS=1
            ;;
        --web-public)
            FLAG_WEB_PUBLIC=1
            SET_WEB_PUBLIC=1
            USED_FLAGS=1
            ;;
        --rdp)
            FLAG_RDP=1
            USED_FLAGS=1
            ;;
        --web-proxy)
            FLAG_WEB=1
            USED_FLAGS=1
            ;;
        --no-prompt)
            NO_PROMPT=1
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

mamori_fw_load_env

if ! MAMORI_FW_BACKEND="$(mamori_fw_detect_backend)"; then
    echo "ERROR: could not detect firewall backend (need Ubuntu/ufw or RHEL/firewalld)" >&2
    exit 1
fi
export MAMORI_FW_BACKEND

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
    elif [[ "$FLAG_DB" -eq 1 && "$SET_INTERNET" -eq 1 ]]; then
        MAMORI_FW_DB_PUBLIC=0
    fi
    if [[ "$SET_RDP_PUBLIC" -eq 1 ]]; then
        MAMORI_FW_RDP_PUBLIC="$FLAG_RDP_PUBLIC"
    elif [[ "$FLAG_RDP" -eq 1 && "$SET_INTERNET" -eq 1 ]]; then
        MAMORI_FW_RDP_PUBLIC=0
    fi
    if [[ "$SET_WEB_PUBLIC" -eq 1 ]]; then
        MAMORI_FW_WEB_PUBLIC="$FLAG_WEB_PUBLIC"
    elif [[ "$FLAG_WEB" -eq 1 && "$SET_INTERNET" -eq 1 ]]; then
        MAMORI_FW_WEB_PUBLIC=0
    fi
    if [[ "$MAMORI_FW_WIREGUARD" == "1" && -z "$FLAG_WG_CIDR" && -z "${MAMORI_FW_WG_CIDR:-}" ]]; then
        MAMORI_FW_WG_CIDR="172.0.0.0/16"
    fi
elif [[ "$NO_PROMPT" -eq 1 ]]; then
    # Keep values from env file / environment
    :
else
    mamori_fw_prompt_profile
fi

if [[ "$MAMORI_FW_WIREGUARD" == "1" && -z "${MAMORI_FW_WG_CIDR:-}" ]]; then
    MAMORI_FW_WG_CIDR="172.0.0.0/16"
fi

# Non-interactive / flag path: refuse public optional ports without --*-public
if [[ "$USED_FLAGS" -eq 1 || "$NO_PROMPT" -eq 1 ]]; then
    if ! mamori_fw_check_public_ports_policy; then
        exit 1
    fi
fi

echo ""
echo "===================================================="
echo " Mamori – Host Firewall Setup"
echo "===================================================="
mamori_fw_print_profile
echo ""

mamori_fw_ensure_package "$MAMORI_FW_BACKEND"

case "$MAMORI_FW_BACKEND" in
    ufw)
        mamori_fw_ufw_apply
        ;;
    firewalld)
        mamori_fw_firewalld_apply
        ;;
    *)
        echo "ERROR: unsupported backend $MAMORI_FW_BACKEND" >&2
        exit 1
        ;;
esac

mamori_fw_save_env

echo ""
echo "Next: bash validate-firewall.sh"
echo ""
