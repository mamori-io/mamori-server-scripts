#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Upgrade nginx inside a running Mamori container to the latest *stable*
# packages from nginx.org (not Ubuntu/RHEL distro nginx).
#
# Mamori images already install nginx from nginx.org and mount /etc/nginx on
# volume mamori-nginx-conf. This script upgrades:
#   nginx + nginx-module-perl
# (perl is required: conf.d uses perl_require / perl status::handler).
#
# Connected sites: pull packages from nginx.org inside the container.
# Air-gapped sites: build a tarball on a connected machine, copy it over, then
# pass --media-file= so nothing is fetched at upgrade time.
#
#   ./nginx-get-media.sh --dir /tmp
#   sudo ./nginx-upgrade-container.sh --upgrade --media-file=/tmp/nginx-org-stable-*.tgz
#
# Config under /etc/nginx is kept (dpkg --force-confold). The new binary
# lives in the container writable layer until the container is recreated
# from a Mamori image (a Mamori upgrade replaces it with the image version).
#
set -euo pipefail

DOCKER="${DOCKER:-sudo docker}"
CONTAINER="${CONTAINER:-mamori}"
MODE=""
DRY_RUN=0
MEDIA_FILE=""

# nginx.org signing key fingerprint (https://nginx.org/en/linux_packages.html)
NGINX_KEY_FINGERPRINT="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62"
INNER_MEDIA_DIR="/tmp/mamori-nginx-org-media"
INNER_MEDIA_TGZ="${INNER_MEDIA_DIR}/media.tgz"

usage() {
  cat <<EOF
Usage: $0 --verify|--upgrade [options]

Upgrade nginx inside the Mamori container from nginx.org stable packages.
Does not upgrade Mamori. Does not use Ubuntu or RHEL nginx packages.

  --verify     Show version, package origin, config test, perl module
  --upgrade    Upgrade nginx + nginx-module-perl, nginx -t, sv restart nginx

Options:
  --container NAME         Container name (default: mamori)
  --media-file=PATH        Air-gap: install from a tarball built by
                           nginx-get-media.sh (no internet required)
  --media-file PATH        Same as --media-file=
  --dry-run                With --upgrade: show what would be installed,
                           do not change the nginx binary
  -h, --help

Air-gapped host:
  sudo $0 --upgrade --media-file=/path/to/nginx-org-stable-VERSION.tgz

Connected host (container must reach nginx.org):
  sudo $0 --upgrade

HA gateway (host nginx) is a different install — use install-host-nginx.sh.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --verify) MODE=verify ;;
    --upgrade) MODE=upgrade ;;
    --dry-run) DRY_RUN=1 ;;
    --media-file=*)
      MEDIA_FILE="${1#--media-file=}"
      ;;
    --media-file)
      shift
      MEDIA_FILE="${1:-}"
      ;;
    --container|-c)
      shift
      CONTAINER="${1:-}"
      [ -n "$CONTAINER" ] || { echo "ERROR: --container needs a name" >&2; exit 1; }
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

[ -n "$MODE" ] || { echo "ERROR: specify --verify or --upgrade" >&2; usage >&2; exit 1; }
if [ "$DRY_RUN" -eq 1 ] && [ "$MODE" != "upgrade" ]; then
  echo "ERROR: --dry-run is only valid with --upgrade" >&2
  exit 1
fi
if [ -n "$MEDIA_FILE" ] && [ "$MODE" != "upgrade" ]; then
  echo "ERROR: --media-file is only valid with --upgrade" >&2
  exit 1
fi
if [ -n "$MEDIA_FILE" ]; then
  [ -n "${MEDIA_FILE}" ] || { echo "ERROR: --media-file needs a path" >&2; exit 1; }
  [ -f "$MEDIA_FILE" ] || { echo "ERROR: media file not found: $MEDIA_FILE" >&2; exit 1; }
fi

if ! $DOCKER inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: docker container '$CONTAINER' not found." >&2
  exit 1
fi
if [ "$($DOCKER inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" != "true" ]; then
  echo "ERROR: container '$CONTAINER' is not running." >&2
  exit 1
fi

INNER_MEDIA=""
if [ -n "$MEDIA_FILE" ]; then
  echo "Copying media file into container '$CONTAINER'..."
  $DOCKER exec "$CONTAINER" mkdir -p "$INNER_MEDIA_DIR"
  $DOCKER cp "$MEDIA_FILE" "${CONTAINER}:${INNER_MEDIA_TGZ}"
  INNER_MEDIA="$INNER_MEDIA_TGZ"
  cleanup_inner_media() {
    $DOCKER exec "$CONTAINER" rm -rf "$INNER_MEDIA_DIR" 2>/dev/null || true
  }
  trap cleanup_inner_media EXIT
fi

# -i is required so the heredoc reaches bash -s (see nginx-update-config.sh).
if ! $DOCKER exec -i "$CONTAINER" bash -s -- "$MODE" "$DRY_RUN" "$NGINX_KEY_FINGERPRINT" "$INNER_MEDIA" <<'EOF'
set -euo pipefail
MODE="$1"
DRY_RUN="$2"
NGINX_KEY_FINGERPRINT="$3"
MEDIA_TGZ="${4:-}"

ok() { echo "  OK: $*"; }
warn() { echo "  WARN: $*"; }
fail() { echo "  FAIL: $*" >&2; exit 1; }

nginx_version() {
  if command -v nginx >/dev/null 2>&1; then
    nginx -v 2>&1 | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
  fi
}

os_id() { . /etc/os-release; echo "${ID:-}"; }
os_codename() { . /etc/os-release; echo "${VERSION_CODENAME:-}"; }
os_major() { . /etc/os-release; echo "${VERSION_ID%%.*}"; }

is_debian_family() {
  case "$(os_id)" in
    ubuntu|debian) return 0 ;;
    *) return 1 ;;
  esac
}

is_rhel_family() {
  case "$(os_id)" in
    rhel|centos|rocky|almalinux|ol|fedora) return 0 ;;
    *) return 1 ;;
  esac
}

container_arch() {
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --print-architecture
    return 0
  fi
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) uname -m ;;
  esac
}

perl_so() {
  for p in \
    /usr/lib/nginx/modules/ngx_http_perl_module.so \
    /etc/nginx/modules/ngx_http_perl_module.so
  do
    if [ -f "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

comment_old_nginx_org_lists() {
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "nginx.list" ] && continue
    if grep -qE 'nginx\.org/packages' "$f" 2>/dev/null; then
      sed -i -E 's|^[[:space:]]*deb(-src)?[[:space:]].*nginx\.org|# &|' "$f"
      ok "commented old nginx.org entries in $f"
    fi
  done
}

ensure_debian_prereqs() {
  export DEBIAN_FRONTEND=noninteractive
  comment_old_nginx_org_lists
  if [ -f /etc/apt/sources.list.d/nginx.list ]; then
    mv /etc/apt/sources.list.d/nginx.list /etc/apt/sources.list.d/nginx.list.bak.$$
  fi
  apt-get update -qq
  apt-get install -y -qq curl gnupg ca-certificates lsb-release >/dev/null
  if [ -f /etc/apt/sources.list.d/nginx.list.bak.$$ ]; then
    mv /etc/apt/sources.list.d/nginx.list.bak.$$ /etc/apt/sources.list.d/nginx.list
  fi
}

install_nginx_org_keyring() {
  mkdir -p /usr/share/keyrings
  local tmp keyring="/usr/share/keyrings/nginx-archive-keyring.gpg"
  tmp=$(mktemp)
  curl -fsSL https://nginx.org/keys/nginx_signing.key -o "$tmp"
  gpg --dearmor < "$tmp" > "$keyring"
  chmod 644 "$keyring"
  rm -f "$tmp"
  local shown
  shown=$(gpg --dry-run --quiet --no-keyring --import --import-options import-show "$keyring" 2>/dev/null || true)
  echo "$shown" | grep -qi "$NGINX_KEY_FINGERPRINT" \
    || fail "nginx.org signing key fingerprint mismatch (expected ${NGINX_KEY_FINGERPRINT})"
  ok "nginx.org signing key ${NGINX_KEY_FINGERPRINT}"
}

setup_nginx_org_apt() {
  local id codename repo
  id=$(os_id)
  codename=$(os_codename)
  [ -n "$codename" ] || fail "could not determine Debian/Ubuntu codename"
  case "$id" in
    ubuntu) repo="https://nginx.org/packages/ubuntu" ;;
    debian) repo="https://nginx.org/packages/debian" ;;
    *) fail "unsupported apt distro: ${id}" ;;
  esac
  echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] ${repo} ${codename} nginx" \
    > /etc/apt/sources.list.d/nginx.list
  cat > /etc/apt/preferences.d/99nginx <<'PIN'
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
PIN
  ok "nginx.org stable repo: ${repo} ${codename}"
}

setup_nginx_org_yum() {
  local major
  major=$(os_major)
  [ -n "$major" ] || fail "could not determine RHEL major version"
  cat > /etc/yum.repos.d/nginx.repo <<YUMREPO
[nginx-stable]
name=nginx stable repo
baseurl=https://nginx.org/packages/centos/${major}/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=https://nginx.org/packages/mainline/centos/${major}/\$basearch/
gpgcheck=1
enabled=0
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
YUMREPO
  ok "nginx.org stable yum repo (centos/${major})"
}

ensure_nginx_org_repo() {
  if is_debian_family; then
    ensure_debian_prereqs
    install_nginx_org_keyring
    comment_old_nginx_org_lists
    setup_nginx_org_apt
    apt-get update -qq
  elif is_rhel_family; then
    setup_nginx_org_yum
    if command -v dnf >/dev/null 2>&1; then
      dnf -q makecache
    else
      yum -q makecache
    fi
  else
    fail "unsupported container OS '$(os_id)'. Need Ubuntu/Debian or RHEL-family for nginx.org packages."
  fi
}

package_origin() {
  if is_debian_family && command -v apt-cache >/dev/null 2>&1; then
    apt-cache policy nginx 2>/dev/null | awk '/Candidate:/ {cand=$2} /nginx.org/ && !seen++ {origin=$0} END {print cand " " origin}'
  elif is_rhel_family; then
    if command -v dnf >/dev/null 2>&1; then
      dnf info nginx 2>/dev/null | awk -F': ' '/^From repo/ {print $2}'
    else
      yum info nginx 2>/dev/null | awk -F': ' '/^From repo/ {print $2}'
    fi
  fi
}

assert_candidate_from_nginx_org() {
  if is_debian_family; then
    local policy
    policy=$(apt-cache policy nginx 2>/dev/null || true)
    echo "$policy" | grep -q nginx.org \
      || fail "apt candidate for nginx is not from nginx.org. Check /etc/apt/sources.list.d/nginx.list"
    if echo "$policy" | grep -q 'packages/mainline'; then
      fail "nginx.org mainline repo is in play; this script only uses stable"
    fi
    ok "apt candidate is from nginx.org stable"
  fi
}

backup_nginx_conf() {
  local stamp dir="/opt/mamori/var/backups"
  stamp=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$dir"
  if tar czf "${dir}/nginx-conf-${stamp}.tgz" -C /etc/nginx --exclude='ssl' . 2>/dev/null; then
    ok "backed up /etc/nginx to ${dir}/nginx-conf-${stamp}.tgz"
  else
    warn "could not tar /etc/nginx; continuing"
  fi
}

find_media_deb() {
  local extract_root="$1" pattern="$2"
  # nginx_*.deb also matches nginx-module-*.deb; exclude modules unless asked.
  if [ "$pattern" = "nginx-module-perl" ]; then
    find "$extract_root" -type f -name "nginx-module-perl_*.deb" | head -1
  else
    find "$extract_root" -type f -name "nginx_*.deb" ! -name 'nginx-module-*' | head -1
  fi
}

find_media_deb_for() {
  local extract_root="$1" kind="$2" codename="$3" arch="$4"
  if [ "$kind" = "nginx-module-perl" ]; then
    find "$extract_root" -type f \
      \( -name "nginx-module-perl_*~${codename}_${arch}.deb" -o \
         -name "nginx-module-perl_*${codename}*${arch}*.deb" \) | head -1
  else
    find "$extract_root" -type f \
      \( -name "nginx_*~${codename}_${arch}.deb" -o \
         -name "nginx_*${codename}*${arch}*.deb" \) \
      ! -name 'nginx-module-*' | head -1
  fi
}

install_from_media() {
  [ -n "$MEDIA_TGZ" ] || fail "internal: media path not set"
  [ -f "$MEDIA_TGZ" ] || fail "media tarball missing inside container: $MEDIA_TGZ"
  local extract
  extract=$(dirname "$MEDIA_TGZ")
  echo "Extracting media..."
  tar xzf "$MEDIA_TGZ" -C "$extract"

  if [ -f "${extract}/nginx-org-stable/MANIFEST" ]; then
    echo "  MANIFEST:"
    sed 's/^/    /' "${extract}/nginx-org-stable/MANIFEST"
  fi

  local id codename arch nginx_deb perl_deb
  id=$(os_id)
  codename=$(os_codename)
  arch=$(container_arch)
  echo "  container: ${id} ${codename} ${arch}"

  nginx_deb=$(find_media_deb_for "$extract" nginx "$codename" "$arch")
  perl_deb=$(find_media_deb_for "$extract" nginx-module-perl "$codename" "$arch")
  [ -n "$nginx_deb" ] || nginx_deb=$(find_media_deb "$extract" nginx)
  [ -n "$perl_deb" ] || perl_deb=$(find_media_deb "$extract" nginx-module-perl)

  [ -n "$nginx_deb" ] || fail "media has no nginx .deb for ${id}/${codename}/${arch}. Rebuild with: nginx-get-media.sh --codename ${codename} --arch ${arch}"
  [ -n "$perl_deb" ] || fail "media has no nginx-module-perl .deb for ${id}/${codename}/${arch}. Rebuild with nginx-get-media.sh."
  echo "  nginx deb: $(basename "$nginx_deb")"
  echo "  perl  deb: $(basename "$perl_deb")"

  if [ "$DRY_RUN" = "1" ]; then
    echo "=== dry-run (no packages installed) ==="
    echo "  would dpkg -i:"
    echo "    $nginx_deb"
    echo "    $perl_deb"
    return 0
  fi

  is_debian_family || fail "media .deb install requires a Debian/Ubuntu container"
  export DEBIAN_FRONTEND=noninteractive
  dpkg --force-confold --force-confdef -i "$nginx_deb" "$perl_deb"
}

upgrade_packages_online() {
  if is_debian_family; then
    export DEBIAN_FRONTEND=noninteractive
    local apt_opts=(
      -y
      -o Dpkg::Options::=--force-confold
      -o Dpkg::Options::=--force-confdef
    )
    if [ "$DRY_RUN" = "1" ]; then
      echo "=== dry-run (no packages installed) ==="
      apt-get install -s "${apt_opts[@]}" nginx nginx-module-perl
      return 0
    fi
    apt-get install "${apt_opts[@]}" nginx nginx-module-perl
  elif is_rhel_family; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "=== dry-run (no packages installed) ==="
      if command -v dnf >/dev/null 2>&1; then
        dnf --assumeno install nginx nginx-module-perl || true
      else
        yum --assumeno install nginx nginx-module-perl || true
      fi
      return 0
    fi
    if command -v dnf >/dev/null 2>&1; then
      dnf -y install nginx nginx-module-perl
    else
      yum -y install nginx nginx-module-perl
    fi
  fi
}

verify_runtime() {
  local ver so
  command -v nginx >/dev/null 2>&1 || fail "nginx binary not found"
  ver=$(nginx_version)
  ok "nginx ${ver:-unknown} ($(command -v nginx))"
  echo "    $(nginx -v 2>&1)"
  if so=$(perl_so); then
    ok "perl module: $so"
  else
    fail "ngx_http_perl_module.so not found (install nginx-module-perl from nginx.org)"
  fi
  if [ -f /etc/nginx/nginx.conf ]; then
    if nginx -t; then
      ok "nginx -t passed"
    else
      fail "nginx -t failed"
    fi
  fi
  if command -v sv >/dev/null 2>&1; then
    sv status nginx || warn "sv status nginx failed"
  fi
}

do_verify() {
  echo "=== Container nginx verify ==="
  echo "  OS: $(os_id) $(os_codename) $(os_major)/$(container_arch)"
  if command -v nginx >/dev/null 2>&1; then
    verify_runtime
  else
    warn "nginx not installed"
  fi
  local origin
  origin=$(package_origin || true)
  if [ -n "$origin" ]; then
    echo "  package: $origin"
  fi
  if is_debian_family && [ -f /etc/apt/sources.list.d/nginx.list ]; then
    echo "  repo: $(tr '\n' ' ' < /etc/apt/sources.list.d/nginx.list)"
  fi
  echo "Verify finished."
}

do_upgrade() {
  local before
  before=$(nginx_version || echo none)
  echo "  current: ${before}"
  if [ -n "$MEDIA_TGZ" ]; then
    echo "=== Container nginx upgrade (media file, no nginx.org fetch) ==="
  else
    echo "=== Container nginx upgrade (nginx.org stable, online) ==="
    ensure_nginx_org_repo
    assert_candidate_from_nginx_org
    echo "  candidate: $(package_origin || echo unknown)"
  fi
  if [ "$DRY_RUN" != "1" ]; then
    backup_nginx_conf
  fi
  if [ -n "$MEDIA_TGZ" ]; then
    install_from_media
  else
    upgrade_packages_online
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "Dry-run finished (nginx still ${before})."
    return 0
  fi
  verify_runtime
  if command -v sv >/dev/null 2>&1; then
    echo "Restarting nginx via runit (reload would keep the old binary)..."
    sv restart nginx
    sleep 2
    sv status nginx || fail "nginx did not come back after sv restart"
  else
    fail "sv not found; nginx was upgraded but not restarted. Restart nginx in the container, then re-run --verify."
  fi
  echo "Upgraded nginx ${before} -> $(nginx_version)"
  echo "Note: recreating this container from a Mamori image restores image nginx."
}

case "$MODE" in
  verify) do_verify ;;
  upgrade) do_upgrade ;;
  *) fail "unknown mode $MODE" ;;
esac
EOF
then
  echo "Error: command failed inside container '$CONTAINER' (see messages above)." >&2
  exit 1
fi
