#!/bin/sh
# In-place Grafana upgrade for AIO / volume-mounted /opt/mamori/grafana.
# Preserves data/, conf/ (jwks, provisioning, custom overrides).
# GRAFANA_TGZ, when set to an existing file, is extracted instead of downloading.
set -e

GRAFANA_VERSION="${GRAFANA_VERSION:-13.2.3}"
GRAFANA_EXTRACT_DIR="grafana-${GRAFANA_VERSION}"
GRAFANA_URL="${GRAFANA_DOWNLOAD_URL:-https://dl.grafana.com/enterprise/release/grafana-enterprise-${GRAFANA_VERSION}.linux-amd64.tar.gz}"
GRAFANA_MIRROR="${GRAFANA_MIRROR_URL:-https://mamori-io.sgp1.digitaloceanspaces.com/install-media/monitoring/grafana-enterprise-${GRAFANA_VERSION}.linux-amd64.tar.gz}"
GRAFANA_HOME="${GRAFANA_HOME:-/opt/mamori/grafana}"

cd "$GRAFANA_HOME"

echo "Stopping grafana..."
sv stop grafana || true

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

TGZ="$WORK/grafana.tgz"
if [ -n "${GRAFANA_TGZ:-}" ]; then
  if [ ! -f "$GRAFANA_TGZ" ]; then
    echo "ERROR: GRAFANA_TGZ not found: $GRAFANA_TGZ" >&2
    exit 1
  fi
  echo "Using local Grafana tarball ${GRAFANA_TGZ}"
  cp "$GRAFANA_TGZ" "$TGZ"
else
  echo "Downloading Grafana ${GRAFANA_VERSION} ..."
  if ! curl -fL --retry 3 --retry-delay 2 -o "$TGZ" "$GRAFANA_MIRROR"; then
    curl -fL --retry 3 --retry-delay 2 -o "$TGZ" "$GRAFANA_URL"
  fi
fi

tar xzf "$TGZ" -C "$WORK"
SRC="$WORK/$GRAFANA_EXTRACT_DIR"
if [ ! -d "$SRC" ]; then
  echo "ERROR: expected ${GRAFANA_EXTRACT_DIR} in download" >&2
  exit 1
fi

# Replace application bits; keep data/ and conf/ intact.
rm -rf bin public LICENSE NOTICE.md VERSION Dockerfile docs plugins conf/defaults.ini
cp -a "$SRC/bin" "$SRC/public" "$GRAFANA_HOME/"
# Grafana 10+ removed grafana-server; keep a shim for older runit/entrypoint scripts.
printf '%s\n' '#!/bin/sh' 'exec "$(dirname "$0")/grafana" server "$@"' > "$GRAFANA_HOME/bin/grafana-server"
chmod +x "$GRAFANA_HOME/bin/grafana-server"
# Prefer unified CLI in runit when present.
if [ -f /etc/service/grafana/run ]; then
  cat > /etc/service/grafana/run <<'EOF'
#!/bin/bash
sv start influxdb || exit 1
if [[ `cat /proc/net/tcp /proc/net/tcp6 | grep -c :1F96` == "0" ]]; then
    echo "not starting grafana as influxdb is not up yet."
    exit 1
fi
sleep 1
if [[ `cat /proc/net/tcp /proc/net/tcp6 | grep -c :0FA0` == "0" ]]; then
    echo "not starting grafana as dm is not up yet."
    exit 1
fi
curl -XPOST 'http://localhost:8086/query' --data-urlencode 'q=CREATE DATABASE "mamori" WITH DURATION 7d'
curl --silent --fail http://localhost:4000/jwks/grafana.json > /opt/mamori/grafana/conf/jwks.json || exit 1
exec /opt/mamori/grafana/bin/grafana server --homepath=/opt/mamori/grafana/
EOF
  chmod +x /etc/service/grafana/run
  cat > /etc/service/grafana/finish <<'EOF'
#!/bin/bash
pkill -f '/opt/mamori/grafana/data/plugins-bundled/' 2>/dev/null || true
exit 0
EOF
  chmod +x /etc/service/grafana/finish
fi
# Optional metadata files when present
for f in LICENSE NOTICE.md VERSION Dockerfile; do
  if [ -e "$SRC/$f" ]; then
    cp -a "$SRC/$f" "$GRAFANA_HOME/"
  fi
done
# Install Grafana package defaults.ini (required for 13.x secrets_manager / alerting).
# Mamori overrides belong in custom.ini so they survive the next upgrade.
mkdir -p "$GRAFANA_HOME/conf"
if [ -f "$SRC/conf/defaults.ini" ]; then
  if [ -f "$GRAFANA_HOME/conf/defaults.ini" ]; then
    cp -a "$GRAFANA_HOME/conf/defaults.ini" "$GRAFANA_HOME/conf/defaults.ini.pre-upgrade.bak"
  fi
  cp -a "$SRC/conf/defaults.ini" "$GRAFANA_HOME/conf/defaults.ini"
  cp -a "$SRC/conf/defaults.ini" "$GRAFANA_HOME/conf/defaults.ini.upstream"
fi
CUSTOM="$GRAFANA_HOME/conf/custom.ini"
touch "$CUSTOM"
SECRET=""
if [ -f "$GRAFANA_HOME/conf/defaults.ini.pre-upgrade.bak" ]; then
  SECRET=$(awk '/^\[security\]/{s=1;next} /^\[/{s=0} s&&/^secret_key[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,"");print;exit}' \
    "$GRAFANA_HOME/conf/defaults.ini.pre-upgrade.bak" || true)
fi
if [ -z "$SECRET" ]; then
  SECRET=$(awk '/^\[security\]/{s=1;next} /^\[/{s=0} s&&/^secret_key[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,"");print;exit}' \
    "$CUSTOM" || true)
fi

# Upsert key in [section]. Creates the section when missing.
ini_set() {
  _file="$1"
  _sec="$2"
  _key="$3"
  _val="$4"
  _tmp=$(mktemp)
  awk -v sec="[$_sec]" -v key="$_key" -v val="$_val" '
    function emit() { print key " = " val }
    BEGIN { done=0; insec=0 }
    $0 == sec {
      print
      insec=1
      next
    }
    insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      emit()
      done=1
      next
    }
    insec && /^\[/ {
      if (!done) emit()
      done=1
      insec=0
    }
    { print }
    END {
      if (insec && !done) emit()
      else if (!done) {
        print ""
        print sec
        emit()
      }
    }
  ' "$_file" > "$_tmp" && mv "$_tmp" "$_file"
}

ini_set "$CUSTOM" "secrets_manager" "encryption_provider" "secret_key.v1"
if [ -n "$SECRET" ]; then
  ini_set "$CUSTOM" "secrets_manager.encryption.secret_key.v1" "secret_key" "$SECRET"
fi
ini_set "$CUSTOM" "unified_alerting.state_history" "enabled" "true"
ini_set "$CUSTOM" "unified_alerting.state_history" "backend" "annotations"
ini_set "$CUSTOM" "unified_alerting.notification_history" "enabled" "false"
ini_set "$CUSTOM" "cloud_migration" "enabled" "false"
ini_set "$CUSTOM" "cloud_migration" "domain" "grafana.net"
ini_set "$CUSTOM" "server" "http_addr" "127.0.0.1"
ini_set "$CUSTOM" "server" "http_port" "3000"
ini_set "$CUSTOM" "server" "root_url" "%(protocol)s://%(domain)s:%(http_port)s/monitor"
ini_set "$CUSTOM" "server" "serve_from_sub_path" "true"
ini_set "$CUSTOM" "auth.jwt" "enabled" "true"
ini_set "$CUSTOM" "auth.jwt" "header_name" "X-JWT-Mamori-Grafana"
ini_set "$CUSTOM" "auth.jwt" "enable_login_token" "true"
ini_set "$CUSTOM" "auth.jwt" "auto_sign_up" "true"
ini_set "$CUSTOM" "auth.jwt" "url_login" "true"
ini_set "$CUSTOM" "auth.jwt" "username_claim" "sub"
ini_set "$CUSTOM" "auth.jwt" "email_claim" "email"
ini_set "$CUSTOM" "auth.jwt" "role_attribute_path" "role"
ini_set "$CUSTOM" "auth.jwt" "jwk_set_file" "/opt/mamori/grafana/conf/jwks.json"
touch "$GRAFANA_HOME/conf/.defaults.keep"

echo "Grafana ${GRAFANA_VERSION} files installed under ${GRAFANA_HOME}"
"$GRAFANA_HOME/bin/grafana" version || "$GRAFANA_HOME/bin/grafana" --version || true

echo "Starting grafana..."
sv start grafana
echo "Done."
