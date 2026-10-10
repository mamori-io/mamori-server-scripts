#!/bin/bash
#
# Shared helpers for HA gateway / host service installers
# (mosquitto, haproxy, host nginx). Source from scripts in ha/ or nginx/.
#
# Mamori LLC copyright 2026.

# Caller must set VERIFY_ERRORS=0 before using fail().
: "${VERIFY_ERRORS:=0}"

ok() { echo "  OK: $*"; }
warn() { echo "  WARN: $*"; }
fail() {
  echo "  FAIL: $*" >&2
  VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo)" >&2
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

systemd_active() {
  local unit="$1"
  systemctl is-active --quiet "$unit" 2>/dev/null
}

systemd_enabled() {
  local unit="$1"
  systemctl is-enabled --quiet "$unit" 2>/dev/null
}

container_exists() {
  local c="$1"
  docker inspect "$c" >/dev/null 2>&1
}

container_running() {
  local c="$1"
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo false)" = "true" ]
}

extract_version() {
  echo "$1" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

backup_file() {
  local src="$1" backup_dir="${2:-/opt/mamori/lb-backup}"
  local base stamp dest
  [ -f "$src" ] || return 0
  mkdir -p "$backup_dir"
  base=$(basename "$src")
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  dest="${backup_dir}/${base}.${stamp}"
  cp -a "$src" "$dest"
  echo "$dest"
}

write_profile_file() {
  # Args: path, then KEY=value lines on stdin (or heredoc via caller)
  local path="$1"
  local tmp
  tmp=$(mktemp)
  cat > "$tmp"
  mkdir -p "$(dirname "$path")"
  mv "$tmp" "$path"
  chmod 644 "$path"
  echo "Wrote profile: ${path}"
}

load_profile_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "ERROR: profile not found: ${path}" >&2
    echo "Run this script with --verify first." >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1090
  . "$path"
  set +a
  echo "Loaded profile: ${path}"
}

apt_install_pkg() {
  local pkg="$1"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y "$pkg"
}

apt_upgrade_pkg() {
  local pkg="$1"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --only-upgrade "$pkg"
}

port_listening() {
  local port="$1"
  if command_exists ss; then
    ss -lntn 2>/dev/null | grep -qE ":${port}\\s"
  elif command_exists netstat; then
    netstat -lnt 2>/dev/null | grep -qE ":${port}\\s"
  else
    return 1
  fi
}
