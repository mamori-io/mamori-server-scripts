#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Discover, verify, install, or upgrade host nginx (any box).
# With --role gateway, also install the Mamori HA load-balancer site.
#
# Flow:
#   sudo ./install-host-nginx.sh --verify
#   sudo ./install-host-nginx.sh --install
#   sudo ./install-host-nginx.sh --role gateway --install --seed-name m1 --seed-ip 10.240.0.11
#   sudo ./install-host-nginx.sh --upgrade
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HA_DIR="$(cd "${SCRIPT_DIR}/../ha" && pwd)"
# shellcheck source=../ha/lib/gateway-service-common.sh
source "${HA_DIR}/lib/gateway-service-common.sh"

ROLE="generic"
NGINX_LB="${NGINX_LB:-/etc/nginx/sites-available/load-balancer}"
BACKUP_DIR="${BACKUP_DIR:-/opt/mamori/lb-backup}"
TEMPLATE="${HA_DIR}/templates/nginx-load-balancer.conf"
PROFILE_PATH="${NGINX_PROFILE:-${SCRIPT_DIR}/gateway-nginx.env}"
SERVER_NAME="_"

MODE=""
FORCE=0
SEED_NAME=""
SEED_IP=""
VERIFY_ERRORS=0

usage() {
  cat <<EOF
Usage: $0 --verify|--install|--upgrade [options]

Install host nginx from the OS package. Optional Mamori HA gateway site.

  --verify    Discover package/config, write profile
  --install   apt install nginx (+ gateway site if --role gateway)
  --upgrade   apt --only-upgrade + nginx -t + reload (needs --verify profile)

Options:
  --role generic|gateway   Default: generic (package only).
                           gateway: install sites-available/load-balancer
  --config PATH            Profile path (default: ${SCRIPT_DIR}/gateway-nginx.env)
  --seed-name NAME         First app hostname for upstream hub [--role gateway --install]
  --seed-ip IP             First app IP; also written to /etc/hosts [--role gateway --install]
  --server-name NAME       nginx server_name (default: _)
  --nginx PATH             Gateway site path (default: sites-available/load-balancer)
  --force                  Replace existing gateway site (backs up first)
  -h, --help

Gateway TLS after install:
  sudo bash nginx-update-gateway-ssl.sh /path/to/fullchain.crt /path/to/privkey.key

App-container nginx (AIO / HA app nodes) uses nginx-update-container-ssl.sh instead.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --verify) MODE=verify ;;
    --install) MODE=install ;;
    --upgrade) MODE=upgrade ;;
    --role)
      shift
      ROLE="${1:-}"
      case "$ROLE" in
        generic|gateway) ;;
        *) echo "ERROR: --role must be generic or gateway" >&2; exit 1 ;;
      esac
      ;;
    --config)
      shift
      PROFILE_PATH="${1:-}"
      ;;
    --seed-name)
      shift
      SEED_NAME="${1:-}"
      ;;
    --seed-ip)
      shift
      SEED_IP="${1:-}"
      ;;
    --server-name)
      shift
      SERVER_NAME="${1:-_}"
      ;;
    --nginx)
      shift
      NGINX_LB="${1:-}"
      ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

[ -n "$MODE" ] || { echo "ERROR: specify --verify, --install, or --upgrade" >&2; usage >&2; exit 1; }

require_root

nginx_version() {
  if command_exists nginx; then
    # nginx -v prints to stderr
    extract_version "$(nginx -v 2>&1)"
  fi
}

ensure_ssl_dir() {
  mkdir -p /etc/nginx/ssl
  if [ ! -f /etc/nginx/ssl/nginx.crt ] || [ ! -f /etc/nginx/ssl/nginx.key ]; then
    warn "TLS cert/key missing under /etc/nginx/ssl — install with nginx-update-gateway-ssl.sh"
    # self-signed so nginx -t can pass until real certs are installed
    if [ ! -f /etc/nginx/ssl/nginx.key ]; then
      openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
        -keyout /etc/nginx/ssl/nginx.key \
        -out /etc/nginx/ssl/nginx.crt \
        -subj "/CN=mamori-gateway-placeholder" 2>/dev/null || true
      ok "wrote placeholder self-signed cert (replace before production)"
    fi
  fi
}

ensure_hosts_entry() {
  local name="$1" ip="$2"
  if grep -qE "[[:space:]]${name}([[:space:]]|\$)" /etc/hosts 2>/dev/null; then
    ok "/etc/hosts already has ${name}"
    return 0
  fi
  echo "${ip} ${name}" >> /etc/hosts
  ok "added /etc/hosts: ${ip} ${name}"
}

install_gateway_site() {
  if [ -z "$SEED_NAME" ] || [ -z "$SEED_IP" ]; then
    echo "ERROR: --role gateway --install requires --seed-name and --seed-ip" >&2
    exit 1
  fi
  [ -f "$TEMPLATE" ] || { echo "ERROR: template missing: ${TEMPLATE}" >&2; exit 1; }

  if [ -f "$NGINX_LB" ] && [ "$FORCE" -ne 1 ]; then
    echo "ERROR: ${NGINX_LB} exists (use --force to replace)" >&2
    exit 1
  fi
  if [ -f "$NGINX_LB" ]; then
    local bak
    bak=$(backup_file "$NGINX_LB" "$BACKUP_DIR")
    ok "backed up to ${bak}"
  fi

  ensure_hosts_entry "$SEED_NAME" "$SEED_IP"
  ensure_ssl_dir

  local tmp
  tmp=$(mktemp)
  sed -e "s/__SEED_NAME__/${SEED_NAME}/g" \
      -e "s/__SEED_IP__/${SEED_IP}/g" \
      -e "s/__SERVER_NAME__/${SERVER_NAME}/g" \
      "$TEMPLATE" > "$tmp"
  mkdir -p "$(dirname "$NGINX_LB")"
  mv "$tmp" "$NGINX_LB"
  chmod 644 "$NGINX_LB"

  local enabled="/etc/nginx/sites-enabled/$(basename "$NGINX_LB")"
  mkdir -p /etc/nginx/sites-enabled
  ln -sfn "$NGINX_LB" "$enabled"
  # Disable default site if present (conflicts with default_server)
  if [ -L /etc/nginx/sites-enabled/default ] || [ -f /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
    ok "removed sites-enabled/default"
  fi
  ok "installed gateway site ${NGINX_LB}"
}

discover_and_verify() {
  echo "=== Host nginx verify (role=${ROLE}) ==="
  VERIFY_ERRORS=0
  local ver="" active="false" has_hub="false"

  if command_exists nginx; then
    ver=$(nginx_version)
    ok "nginx installed (version ${ver:-unknown})"
  else
    warn "nginx not installed (ok before --install)"
  fi

  if systemd_active nginx; then
    active=true
    ok "nginx service active"
  else
    warn "nginx service not active"
  fi

  if command_exists nginx && [ -f /etc/nginx/nginx.conf ]; then
    if nginx -t >/dev/null 2>&1; then
      ok "nginx -t passed"
    else
      fail "nginx -t failed"
    fi
  fi

  if [ "$ROLE" = "gateway" ]; then
    if [ -f "$NGINX_LB" ]; then
      ok "gateway site present: ${NGINX_LB}"
      if grep -qE 'upstream[[:space:]]+hub[[:space:]]*\{' "$NGINX_LB"; then
        has_hub=true
        ok "upstream hub block found"
      else
        fail "gateway site missing 'upstream hub { ... }' (required by manage-lb-node.sh)"
      fi
      if grep -q 'X-Real-IP' "$NGINX_LB"; then
        ok "X-Real-IP header present"
      else
        warn "X-Real-IP not found in gateway site"
      fi
    else
      warn "gateway site missing: ${NGINX_LB}"
    fi
  fi

  if [ "$VERIFY_ERRORS" -gt 0 ]; then
    echo "Verify FAILED with ${VERIFY_ERRORS} error(s). Profile NOT written." >&2
    exit 1
  fi

  write_profile_file "$PROFILE_PATH" <<EOF
# Generated by install-host-nginx.sh --verify
PROFILE_VERSION=1
DISCOVERED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
NGINX_ROLE=${ROLE}
NGINX_VERSION=${ver}
NGINX_ACTIVE=${active}
NGINX_LB=${NGINX_LB}
NGINX_HAS_UPSTREAM_HUB=${has_hub}
EOF
  echo "Verify PASSED."
}

do_install() {
  echo "=== Host nginx install (role=${ROLE}) ==="
  if ! command_exists nginx; then
    apt_install_pkg nginx
  else
    ok "nginx already installed"
  fi

  if [ "$ROLE" = "gateway" ]; then
    install_gateway_site
  fi

  nginx -t
  systemctl enable nginx
  systemctl restart nginx
  ok "nginx enabled and restarted"
  if [ "$ROLE" = "gateway" ]; then
    echo "Next: bash nginx-update-gateway-ssl.sh <cert> <key>"
    echo "Then: bash manage-lb-node.sh --register --name ${SEED_NAME} --ip ${SEED_IP}"
  fi
}

do_upgrade() {
  echo "=== Host nginx upgrade ==="
  load_profile_file "$PROFILE_PATH"
  ROLE="${NGINX_ROLE:-$ROLE}"
  NGINX_LB="${NGINX_LB:-/etc/nginx/sites-available/load-balancer}"

  apt_upgrade_pkg nginx
  nginx -t
  systemctl reload nginx
  ok "nginx upgraded and reloaded (site config not overwritten)"
}

case "$MODE" in
  verify) discover_and_verify ;;
  install) do_install ;;
  upgrade) do_upgrade ;;
esac
