#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Download latest *stable* nginx.org packages into a tarball for air-gapped
# Mamori container upgrades. Run this on a machine with internet access, then
# copy the .tgz to the air-gapped host.
#
# Packages come from nginx.org (not Ubuntu/RHEL distro nginx). The tarball is
# matched to the *container* OS (Ubuntu noble/jammy, etc.), not the host OS.
#
# Also fetches Ubuntu/Debian *perl* runtime deps required by nginx-module-perl
# (perl, libperl*, …) from the distro archive so air-gapped dpkg -i can succeed
# when the container's perl is older than the module's Depends.
#
# Usage:
#   ./nginx-get-media.sh
#   ./nginx-get-media.sh --codename noble --arch amd64 --dir /tmp
#   ./nginx-get-media.sh --codename noble,jammy
#   ./nginx-get-media.sh --from-container mamori
#
# Then on the Mamori host:
#   sudo ./nginx-upgrade-container.sh --upgrade --media-file=/path/to/nginx-org-stable-*.tgz
#
set -euo pipefail

DOCKER="${DOCKER:-sudo docker}"
DISTRO="ubuntu"
CODENAMES="noble"
ARCH="amd64"
OUT_DIR="$(pwd)"
FORCE=0
FROM_CONTAINER=""

NGINX_KEY_URL="https://nginx.org/keys/nginx_signing.key"
NGINX_KEY_FINGERPRINT="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62"

usage() {
  cat <<EOF
Usage: $0 [options]

Download nginx.org stable packages (nginx + nginx-module-perl) plus the
Ubuntu/Debian perl deps those packages need into a .tgz for air-gapped
\`nginx-upgrade-container.sh --media-file=\`.

Target the *container* release/arch (not this download host):
  --codename noble,jammy --arch amd64

Options:
  --distro ubuntu|debian     Default: ubuntu (Mamori container)
  --codename NAME[,NAME]     Ubuntu/Debian codename(s). Default: noble
  --arch amd64|arm64         Default: amd64
  --from-container NAME      Read distro/codename/arch from a running container
  --dir PATH                 Output directory (default: current directory)
  --force                    Overwrite existing tarball
  -h, --help

Examples:
  bash nginx-get-media.sh
  bash nginx-get-media.sh --codename noble,jammy --dir .
  bash nginx-get-media.sh --from-container mamori --dir /tmp
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --distro)
      shift
      DISTRO="${1:-}"
      [ -n "$DISTRO" ] || { echo "ERROR: --distro needs a value" >&2; exit 1; }
      ;;
    --codename)
      shift
      CODENAMES="${1:-}"
      [ -n "$CODENAMES" ] || { echo "ERROR: --codename needs a value" >&2; exit 1; }
      ;;
    --arch)
      shift
      ARCH="${1:-}"
      [ -n "$ARCH" ] || { echo "ERROR: --arch needs a value" >&2; exit 1; }
      ;;
    --from-container)
      shift
      FROM_CONTAINER="${1:-}"
      [ -n "$FROM_CONTAINER" ] || { echo "ERROR: --from-container needs a name" >&2; exit 1; }
      ;;
    --dir|-d)
      shift
      OUT_DIR="${1:-}"
      [ -n "$OUT_DIR" ] || { echo "ERROR: --dir needs a path" >&2; exit 1; }
      ;;
    --force|-f) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

case "$DISTRO" in
  ubuntu|debian) ;;
  *)
    echo "ERROR: --distro must be ubuntu or debian (got: $DISTRO)" >&2
    exit 1
    ;;
esac
case "$ARCH" in
  amd64|arm64) ;;
  *)
    echo "ERROR: --arch must be amd64 or arm64 (got: $ARCH)" >&2
    exit 1
    ;;
esac

if [ -n "$FROM_CONTAINER" ]; then
  if ! $DOCKER inspect "$FROM_CONTAINER" >/dev/null 2>&1; then
    echo "ERROR: container '$FROM_CONTAINER' not found" >&2
    exit 1
  fi
  DISTRO=$($DOCKER exec "$FROM_CONTAINER" bash -c '. /etc/os-release; echo "$ID"')
  CODENAMES=$($DOCKER exec "$FROM_CONTAINER" bash -c '. /etc/os-release; echo "$VERSION_CODENAME"')
  ARCH=$($DOCKER exec "$FROM_CONTAINER" dpkg --print-architecture 2>/dev/null || echo amd64)
  echo "From container ${FROM_CONTAINER}: distro=${DISTRO} codename=${CODENAMES} arch=${ARCH}"
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required to download nginx.org packages" >&2
  exit 1
fi

download() {
  local url="$1" dest="$2"
  echo "  GET $url"
  curl -fsSL --retry 3 -o "$dest" "$url"
}

# Print "version filename" lines for the named package from an apt Packages file.
pkg_records() {
  local packages_file="$1" want="$2"
  awk -v want="$want" '
    BEGIN { RS=""; FS="\n" }
    {
      pkg=""; ver=""; file=""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Package: /)  { split($i, a, " "); pkg = a[2] }
        if ($i ~ /^Version: /)  { split($i, a, " "); ver = a[2] }
        if ($i ~ /^Filename: /) { split($i, a, " "); file = a[2] }
      }
      if (pkg == want && file != "") { print ver " " file }
    }
  ' "$packages_file"
}

# Latest record (debian-style version sort). Optional $3 pins an exact version.
pkg_record() {
  local packages_file="$1" want="$2" pin_ver="${3:-}"
  local recs
  recs=$(pkg_records "$packages_file" "$want")
  [ -n "$recs" ] || return 1
  if [ -n "$pin_ver" ]; then
    local hit
    hit=$(echo "$recs" | awk -v v="$pin_ver" '$1 == v { print; exit }')
    [ -n "$hit" ] || return 1
    echo "$hit"
    return 0
  fi
  echo "$recs" | sort -k1,1 -V | tail -1
}

assert_deb() {
  local f="$1"
  local size magic
  size=$(wc -c < "$f" | tr -d ' ')
  if [ "$size" -lt 10000 ]; then
    echo "ERROR: $f is too small (${size} bytes) — not a debian package" >&2
    exit 1
  fi
  magic=$(head -c 7 "$f" || true)
  if [ "$magic" != "!<arch>" ]; then
    echo "ERROR: $f is not a .deb (missing ar header)" >&2
    exit 1
  fi
}

# Read a control field from a .deb (Depends, Pre-Depends, …).
deb_field() {
  local deb="$1" field="$2"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -f "$deb" "$field" 2>/dev/null || true
    return 0
  fi
  local tmp control_tar
  tmp=$(mktemp -d)
  (
    cd "$tmp"
    ar x "$deb" >/dev/null
    control_tar=$(ls control.tar.* 2>/dev/null | head -1)
    [ -n "$control_tar" ] || exit 1
    tar xf "$control_tar"
    awk -v f="$field" '
      BEGIN { IGNORECASE=0 }
      $0 ~ ("^" f ":") {
        sub(/^[^:]+:[[:space:]]*/, "")
        val=$0
        while (getline > 0 && $0 ~ /^[[:space:]]/) {
          sub(/^[[:space:]]+/, "")
          val=val " " $0
        }
        print val
        exit
      }
    ' control
  )
  rm -rf "$tmp"
}

# Base URL for distro pool downloads (amd64 vs ports).
distro_archive_base() {
  case "$DISTRO" in
    ubuntu)
      if [ "$ARCH" = "amd64" ]; then
        echo "http://archive.ubuntu.com/ubuntu"
      else
        echo "http://ports.ubuntu.com/ubuntu-ports"
      fi
      ;;
    debian)
      echo "http://deb.debian.org/debian"
      ;;
  esac
}

# Append Packages.gz contents from a distro suite into $1.
append_distro_packages() {
  local out="$1" suite="$2" component="$3"
  local base gz
  base=$(distro_archive_base)
  gz="${WORK}/pkgidx-${suite}-${component}-${ARCH}.gz"
  if download "${base}/dists/${suite}/${component}/binary-${ARCH}/Packages.gz" "$gz" 2>/dev/null; then
    gzip -dc "$gz" >> "$out"
    echo "" >> "$out"
    rm -f "$gz"
    return 0
  fi
  return 1
}

# Build a merged Packages index for codename (+ updates/security for Ubuntu).
build_distro_packages_index() {
  local codename="$1" out="$2"
  : > "$out"
  case "$DISTRO" in
    ubuntu)
      append_distro_packages "$out" "$codename" main || true
      append_distro_packages "$out" "${codename}-updates" main || true
      append_distro_packages "$out" "${codename}-security" main || true
      # perl is in main; universe as a fallback for odd deps
      append_distro_packages "$out" "$codename" universe || true
      append_distro_packages "$out" "${codename}-updates" universe || true
      append_distro_packages "$out" "${codename}-security" universe || true
      ;;
    debian)
      append_distro_packages "$out" "$codename" main || true
      append_distro_packages "$out" "${codename}-updates" main || true
      ;;
  esac
  [ -s "$out" ] || {
    echo "ERROR: could not download ${DISTRO} Packages indexes for ${codename}/${ARCH}" >&2
    exit 1
  }
}

# Package names from a Depends/Pre-Depends line (first alternative of each clause).
depend_package_names() {
  local depends_line="$1"
  [ -n "$depends_line" ] || return 0
  echo "$depends_line" | tr ',' '\n' | while read -r clause; do
    clause=$(echo "$clause" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$clause" ] || continue
    # first alternative before |
    clause=${clause%%|*}
    clause=$(echo "$clause" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # strip version and arch qualifiers: pkg (>= 1.2), pkg:any
    local name
    name=$(echo "$clause" | awk '{print $1}' | sed 's/:.*//')
    case "$name" in
      ""|nginx|nginx-module-perl) continue ;;
    esac
    # Only perl runtime deps — keeps media small and fixes known air-gap failures.
    case "$name" in
      perl|perl-*|libperl*)
        echo "$name"
        ;;
    esac
  done
}

# Download Ubuntu/Debian perl-related deps required by nginx-module-perl.
fetch_distro_perl_deps() {
  local module_deb="$1" codename="$2" dest_dir="$3"
  local deps_dir="${dest_dir}/distro-deps"
  local idx depends pre names name rec ver file base dest
  local fetched=0

  mkdir -p "$deps_dir"
  idx="${dest_dir}/DistroPackages"
  echo "  Fetching ${DISTRO} package indexes for perl deps (${codename}/${ARCH})..."
  build_distro_packages_index "$codename" "$idx"

  depends=$(deb_field "$module_deb" Depends)
  pre=$(deb_field "$module_deb" Pre-Depends)
  names=$(
    {
      depend_package_names "$depends"
      depend_package_names "$pre"
    } | sort -u
  )

  if [ -z "$names" ]; then
    echo "  WARN: no perl/libperl Depends parsed from $(basename "$module_deb"); distro-deps may be empty"
    return 0
  fi

  base=$(distro_archive_base)
  echo "  Distro perl deps to fetch:"
  for name in $names; do
    rec=$(pkg_record "$idx" "$name" || true)
    if [ -z "$rec" ]; then
      echo "    SKIP ${name} (not in ${DISTRO} Packages — likely virtual)"
      continue
    fi
    ver=${rec%% *}
    file=${rec#* }
    dest="${deps_dir}/$(basename "$file")"
    echo "    ${name} ${ver}"
    download "${base}/${file}" "$dest"
    assert_deb "$dest"
    fetched=$((fetched + 1))

    # One level: if we pulled perl, also pull matching libperl* it Depends on.
    if [ "$name" = "perl" ]; then
      local perl_deps drec dver dfile ddest dname
      perl_deps=$(deb_field "$dest" Depends)
      for dname in $(depend_package_names "$perl_deps"); do
        [ "$dname" != "perl" ] || continue
        drec=$(pkg_record "$idx" "$dname" || true)
        [ -n "$drec" ] || continue
        dver=${drec%% *}
        dfile=${drec#* }
        ddest="${deps_dir}/$(basename "$dfile")"
        if [ -f "$ddest" ]; then
          continue
        fi
        echo "    ${dname} ${dver} (via perl)"
        download "${base}/${dfile}" "$ddest"
        assert_deb "$ddest"
        fetched=$((fetched + 1))
      done
    fi
  done

  echo "  distro-deps: ${fetched} package(s) in ${deps_dir}"
  # Record names for MANIFEST aggregation
  DISTRO_DEPS_ALL="${DISTRO_DEPS_ALL} $(ls -1 "$deps_dir" 2>/dev/null | tr '\n' ' ')"
}

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ROOT="${WORK}/nginx-org-stable"
mkdir -p "$ROOT"

echo "Downloading nginx.org signing key..."
download "$NGINX_KEY_URL" "${ROOT}/nginx_signing.key"
if command -v gpg >/dev/null 2>&1; then
  shown=$(gpg --show-keys --with-colons "${ROOT}/nginx_signing.key" 2>/dev/null || true)
  echo "$shown" | grep -qi "$NGINX_KEY_FINGERPRINT" \
    || { echo "ERROR: nginx.org key fingerprint mismatch (expected ${NGINX_KEY_FINGERPRINT})" >&2; exit 1; }
  echo "  OK fingerprint ${NGINX_KEY_FINGERPRINT}"
else
  echo "  WARN: gpg not on this host; key fingerprint not verified"
fi

NGINX_VERSION=""
CODENAME_LIST=""
DISTRO_DEPS_ALL=""
IFS=',' read -r -a CODE_ARR <<< "$CODENAMES"
for raw in "${CODE_ARR[@]}"; do
  codename=$(echo "$raw" | tr -d ' ')
  [ -n "$codename" ] || continue
  CODENAME_LIST="${CODENAME_LIST} ${codename}"
  dest_dir="${ROOT}/${DISTRO}/${codename}/${ARCH}"
  mkdir -p "$dest_dir"
  pkg_index="https://nginx.org/packages/${DISTRO}/dists/${codename}/nginx/binary-${ARCH}"
  echo "Fetching package index for ${DISTRO}/${codename}/${ARCH}..."
  if ! download "${pkg_index}/Packages" "${dest_dir}/Packages" 2>/dev/null; then
    download "${pkg_index}/Packages.gz" "${dest_dir}/Packages.gz"
    gzip -dc "${dest_dir}/Packages.gz" > "${dest_dir}/Packages"
    rm -f "${dest_dir}/Packages.gz"
  fi

  nginx_rec=$(pkg_record "${dest_dir}/Packages" nginx)
  [ -n "$nginx_rec" ] || { echo "ERROR: nginx not in Packages for ${codename}/${ARCH}" >&2; exit 1; }
  nginx_ver=${nginx_rec%% *}
  nginx_file=${nginx_rec#* }
  perl_rec=$(pkg_record "${dest_dir}/Packages" nginx-module-perl "$nginx_ver")
  [ -n "$perl_rec" ] || { echo "ERROR: nginx-module-perl ${nginx_ver} not in Packages for ${codename}/${ARCH}" >&2; exit 1; }
  perl_ver=${perl_rec%% *}
  perl_file=${perl_rec#* }

  if [ -z "$NGINX_VERSION" ]; then
    NGINX_VERSION="$nginx_ver"
  fi
  echo "  nginx ${nginx_ver}"
  echo "  nginx-module-perl ${perl_ver}"

  download "https://nginx.org/packages/${DISTRO}/${nginx_file}" "${dest_dir}/$(basename "$nginx_file")"
  download "https://nginx.org/packages/${DISTRO}/${perl_file}" "${dest_dir}/$(basename "$perl_file")"
  assert_deb "${dest_dir}/$(basename "$nginx_file")"
  assert_deb "${dest_dir}/$(basename "$perl_file")"

  fetch_distro_perl_deps "${dest_dir}/$(basename "$perl_file")" "$codename" "$dest_dir"
done

CODENAME_LIST=$(echo "$CODENAME_LIST" | xargs)
SHORT_VER=$(echo "$NGINX_VERSION" | grep -Eo '^[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
SAFE_CODES=$(echo "$CODENAME_LIST" | tr ' ' '-')
if [ "$(echo "$CODENAME_LIST" | wc -w | tr -d ' ')" -eq 1 ]; then
  OUT_NAME="nginx-org-stable-${SHORT_VER}-${DISTRO}-${SAFE_CODES}-${ARCH}.tgz"
else
  OUT_NAME="nginx-org-stable-${SHORT_VER}-${DISTRO}-${ARCH}.tgz"
fi

DISTRO_DEPS_ALL=$(echo "$DISTRO_DEPS_ALL" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
cat > "${ROOT}/MANIFEST" <<EOF
MEDIA_TYPE=nginx-org-stable
NGINX_VERSION=${NGINX_VERSION}
DISTRO=${DISTRO}
CODENAMES=${CODENAME_LIST}
ARCH=${ARCH}
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SOURCE=https://nginx.org/packages/${DISTRO}
PACKAGES=nginx nginx-module-perl
DISTRO_PERL_DEPS=${DISTRO_DEPS_ALL:-none}
EOF

mkdir -p "$OUT_DIR"
DEST="${OUT_DIR%/}/${OUT_NAME}"
if [ -f "$DEST" ] && [ "$FORCE" -ne 1 ]; then
  echo "ERROR: $DEST already exists (use --force to overwrite)" >&2
  exit 1
fi

tar czf "$DEST" -C "$WORK" nginx-org-stable
SIZE=$(wc -c < "$DEST" | tr -d ' ')
echo "Wrote $DEST (${SIZE} bytes)"
echo "  version: ${NGINX_VERSION}"
echo "  target:  ${DISTRO} ${CODENAME_LIST} ${ARCH}"
echo
echo "On the air-gapped Mamori host:"
echo "  sudo ./nginx-upgrade-container.sh --upgrade --media-file=${DEST}"
