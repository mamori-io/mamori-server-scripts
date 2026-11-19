#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Shared helpers for OpenBao host install / Mamori bootstrap / uninstall.
#

OPENBAO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Package defaults (GitHub .deb — pkg.openbao.org DNS is unreliable on some labs).
OPENBAO_VERSION="${OPENBAO_VERSION:-2.7.2}"
OPENBAO_ARCH="${OPENBAO_ARCH:-linux_amd64}"
OPENBAO_DEB_URL="${OPENBAO_DEB_URL:-https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/openbao_${OPENBAO_VERSION}_${OPENBAO_ARCH}.deb}"
OPENBAO_CHECKSUMS_URL="${OPENBAO_CHECKSUMS_URL:-https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/checksums.txt}"

# API / bootstrap defaults
BAO_ADDR="${BAO_ADDR:-https://127.0.0.1:8200}"
BAO_SKIP_VERIFY="${BAO_SKIP_VERIFY:-1}"
BAO_KV_MOUNT="${BAO_KV_MOUNT:-secret}"
BAO_POLICY_NAME="${BAO_POLICY_NAME:-mamori}"
BAO_ROLE_NAME="${BAO_ROLE_NAME:-mamori}"
BAO_SECRET_PREFIX="${BAO_SECRET_PREFIX:-mamori}"

CACHE_DIR="${CACHE_DIR:-$OPENBAO_ROOT/cache}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
    done
}

# Base curl flags. Pass "nofail" as $1 to omit -f (for sys/health sealed/uninit codes).
curl_opts() {
    local opts=(-sS --connect-timeout 10 --max-time 60)
    if [[ "${1:-}" != "nofail" ]]; then
        opts+=(-f)
    fi
    if [[ "${BAO_SKIP_VERIFY}" == "1" || "${BAO_SKIP_VERIFY}" == "true" ]]; then
        opts+=(-k)
    fi
    printf '%s\n' "${opts[@]}"
}

# bao_api METHOD PATH [curl --data args...]
# Uses BAO_ADDR and optional BAO_TOKEN (X-Vault-Token). Fails on HTTP errors.
bao_api() {
    local method="$1"
    local path="$2"
    shift 2
    local url="${BAO_ADDR%/}/v1/${path#/}"
    local -a opts
    mapfile -t opts < <(curl_opts)
    opts+=(-X "$method" "$url" -H "Content-Type: application/json")
    if [[ -n "${BAO_TOKEN:-}" ]]; then
        opts+=(-H "X-Vault-Token: ${BAO_TOKEN}")
    fi
    curl "${opts[@]}" "$@"
}

# Like bao_api but allows non-2xx. Prints body then a final line with HTTP code.
bao_api_code() {
    local method="$1"
    local path="$2"
    shift 2
    local url="${BAO_ADDR%/}/v1/${path#/}"
    local -a opts
    mapfile -t opts < <(curl_opts nofail)
    opts+=(-X "$method" "$url" -H "Content-Type: application/json" -w "\n%{http_code}")
    if [[ -n "${BAO_TOKEN:-}" ]]; then
        opts+=(-H "X-Vault-Token: ${BAO_TOKEN}")
    fi
    curl "${opts[@]}" "$@"
}

detect_debian_family() {
    [[ -f /etc/os-release ]] || return 1
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID_LIKE:-}${ID:-}" in
        *debian*|*ubuntu*) return 0 ;;
        *) return 1 ;;
    esac
}

openbao_installed() {
    command -v bao >/dev/null 2>&1 || dpkg -l openbao 2>/dev/null | grep -q '^ii'
}

service_active() {
    systemctl is-active --quiet openbao 2>/dev/null
}
