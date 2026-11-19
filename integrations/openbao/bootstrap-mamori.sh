#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Configure an initialized OpenBao for Mamori: unseal (if needed), enable
# KV-v2 + AppRole, write mamori policy/role, smoke-test, write connection JSON.
#
# Usage:
#   bash bootstrap-mamori.sh --addr https://HOST:8200 --state /path/to/openbao-state.json
#   bash bootstrap-mamori.sh --addr https://HOST:8200 --state state.json --out /tmp/mamori-openbao.json
#
# State JSON shape (from bao operator init -format=json):
#   { "keys": ["..."], "keys_base64": ["..."], "root_token": "s...." }
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

STATE_FILE=""
OUT_FILE=""
ADDR_SET=0

usage() {
    cat <<EOF
Usage: $0 --addr URL --state FILE [--out FILE]

Unseal (if sealed), enable KV-v2 at ${BAO_KV_MOUNT}/ and AppRole, create
policy/role ${BAO_ROLE_NAME}, smoke-test KV under ${BAO_SECRET_PREFIX}/, write
Mamori connection JSON (chmod 600).

  --addr URL     OpenBao API base (default: ${BAO_ADDR})
  --state FILE   Init state JSON with root_token and unseal keys
  --out FILE     Connection JSON path (default: ./mamori-openbao-connection.json)
  -h, --help

Environment:
  BAO_SKIP_VERIFY=1   skip TLS verify (default; self-signed lab certs)
  BAO_KV_MOUNT        default secret
  BAO_POLICY_NAME     default mamori
  BAO_ROLE_NAME       default mamori
  BAO_SECRET_PREFIX   default mamori
  BAO_TOKEN           optional override instead of state root_token
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --addr)
            BAO_ADDR="${2:?}"
            ADDR_SET=1
            shift 2
            ;;
        --state)
            STATE_FILE="${2:?}"
            shift 2
            ;;
        --out)
            OUT_FILE="${2:?}"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

export BAO_ADDR

require_cmd curl jq

[[ -n "$STATE_FILE" ]] || die "--state FILE is required"
[[ -f "$STATE_FILE" ]] || die "state file not found: $STATE_FILE"
[[ "$ADDR_SET" -eq 1 || -n "${BAO_ADDR:-}" ]] || die "--addr URL is required"

if [[ -z "$OUT_FILE" ]]; then
    OUT_FILE="$(pwd)/mamori-openbao-connection.json"
fi

ROOT_TOKEN="$(jq -r '.root_token // empty' "$STATE_FILE")"
if [[ -z "${BAO_TOKEN:-}" ]]; then
    [[ -n "$ROOT_TOKEN" ]] || die "state file missing root_token"
    BAO_TOKEN="$ROOT_TOKEN"
fi
export BAO_TOKEN

mapfile -t UNSEAL_KEYS < <(jq -r '.keys_base64[]? // empty' "$STATE_FILE")
if [[ ${#UNSEAL_KEYS[@]} -eq 0 ]]; then
    mapfile -t UNSEAL_KEYS < <(jq -r '.keys[]? // empty' "$STATE_FILE")
fi

log "OpenBao addr=${BAO_ADDR} skip_verify=${BAO_SKIP_VERIFY}"

# --- health / unseal ---
health_body="$(bao_api_code GET sys/health || true)"
health_code="$(printf '%s\n' "$health_body" | tail -n1)"
health_json="$(printf '%s\n' "$health_body" | sed '$d')"

# 200 initialized+unsealed, 429 sealed, 501 not initialized, 472 standby, etc.
initialized="$(printf '%s' "$health_json" | jq -r '.initialized // false')"
sealed="$(printf '%s' "$health_json" | jq -r '.sealed // true')"
log "health http=${health_code} initialized=${initialized} sealed=${sealed}"

if [[ "$initialized" != "true" ]]; then
    die "OpenBao is not initialized. Run: bao operator init -format=json > state.json"
fi

if [[ "$sealed" == "true" ]]; then
    [[ ${#UNSEAL_KEYS[@]} -gt 0 ]] || die "OpenBao is sealed and state file has no keys / keys_base64"
    log "Unsealing..."
    for key in "${UNSEAL_KEYS[@]}"; do
        [[ -n "$key" ]] || continue
        resp="$(bao_api POST sys/unseal -d "$(jq -nc --arg k "$key" '{key:$k}')")"
        sealed="$(printf '%s' "$resp" | jq -r '.sealed')"
        log "unseal progress sealed=${sealed} progress=$(printf '%s' "$resp" | jq -r '.progress // empty')"
        if [[ "$sealed" == "false" ]]; then
            break
        fi
    done
    sealed="$(bao_api GET sys/seal-status | jq -r '.sealed')"
    [[ "$sealed" == "false" ]] || die "still sealed after submitting keys"
    log "Unsealed"
fi

# --- mounts: KV v2 ---
mounts="$(bao_api GET sys/mounts)"
kv_type="$(printf '%s' "$mounts" | jq -r --arg m "${BAO_KV_MOUNT}/" '.[$m].type // empty')"
kv_ver="$(printf '%s' "$mounts" | jq -r --arg m "${BAO_KV_MOUNT}/" '.[$m].options.version // empty')"

if [[ -z "$kv_type" ]]; then
    log "Enabling kv-v2 at ${BAO_KV_MOUNT}/"
    bao_api POST "sys/mounts/${BAO_KV_MOUNT}" -d '{"type":"kv","options":{"version":"2"}}' >/dev/null
elif [[ "$kv_type" == "kv" && "$kv_ver" != "2" ]]; then
    log "Tuning ${BAO_KV_MOUNT}/ to kv version 2"
    bao_api POST "sys/mounts/${BAO_KV_MOUNT}/tune" -d '{"options":{"version":"2"}}' >/dev/null
else
    log "KV mount ${BAO_KV_MOUNT}/ already present (type=${kv_type} version=${kv_ver:-?})"
fi

# --- auth: AppRole ---
auths="$(bao_api GET sys/auth)"
approle_type="$(printf '%s' "$auths" | jq -r '.["approle/"].type // empty')"
if [[ -z "$approle_type" ]]; then
    log "Enabling approle auth"
    bao_api POST sys/auth/approle -d '{"type":"approle"}' >/dev/null
else
    log "AppRole auth already enabled"
fi

# --- policy ---
POLICY_HCL=$(cat <<EOF
# Mamori OpenBao integration — KV under ${BAO_SECRET_PREFIX}/
path "${BAO_KV_MOUNT}/data/${BAO_SECRET_PREFIX}/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}
path "${BAO_KV_MOUNT}/metadata/${BAO_SECRET_PREFIX}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "${BAO_KV_MOUNT}/delete/${BAO_SECRET_PREFIX}/*" {
  capabilities = ["update"]
}
path "${BAO_KV_MOUNT}/undelete/${BAO_SECRET_PREFIX}/*" {
  capabilities = ["update"]
}
path "${BAO_KV_MOUNT}/destroy/${BAO_SECRET_PREFIX}/*" {
  capabilities = ["update"]
}
path "${BAO_KV_MOUNT}/metadata" {
  capabilities = ["list"]
}
path "${BAO_KV_MOUNT}/metadata/${BAO_SECRET_PREFIX}" {
  capabilities = ["list"]
}
EOF
)

log "Writing policy ${BAO_POLICY_NAME}"
bao_api PUT "sys/policies/acl/${BAO_POLICY_NAME}" \
    -d "$(jq -nc --arg p "$POLICY_HCL" '{policy:$p}')" >/dev/null

# --- AppRole role ---
log "Creating/updating AppRole ${BAO_ROLE_NAME}"
bao_api POST "auth/approle/role/${BAO_ROLE_NAME}" -d "$(jq -nc \
    --arg pol "$BAO_POLICY_NAME" \
    '{
      token_policies: [$pol],
      token_ttl: "1h",
      token_max_ttl: "4h",
      bind_secret_id: true,
      secret_id_ttl: "0"
    }')" >/dev/null

ROLE_ID="$(bao_api GET "auth/approle/role/${BAO_ROLE_NAME}/role-id" | jq -r '.data.role_id')"
[[ -n "$ROLE_ID" && "$ROLE_ID" != "null" ]] || die "failed to read role_id"

SECRET_ID="$(bao_api POST "auth/approle/role/${BAO_ROLE_NAME}/secret-id" -d '{}' | jq -r '.data.secret_id')"
[[ -n "$SECRET_ID" && "$SECRET_ID" != "null" ]] || die "failed to generate secret_id"

log "AppRole role_id=${ROLE_ID}"

# --- smoke: login + KV ---
log "Smoke: AppRole login"
login_json="$(bao_api POST auth/approle/login -d "$(jq -nc --arg r "$ROLE_ID" --arg s "$SECRET_ID" '{role_id:$r,secret_id:$s}')")"
APP_TOKEN="$(printf '%s' "$login_json" | jq -r '.auth.client_token')"
[[ -n "$APP_TOKEN" && "$APP_TOKEN" != "null" ]] || die "AppRole login failed"

SMOKE_PATH="${BAO_KV_MOUNT}/data/${BAO_SECRET_PREFIX}/smoke"
SMOKE_VALUE="ok-$(date -u +%Y%m%dT%H%M%SZ)"

log "Smoke: KV put ${SMOKE_PATH}"
BAO_TOKEN="$APP_TOKEN" bao_api POST "$SMOKE_PATH" \
    -d "$(jq -nc --arg v "$SMOKE_VALUE" '{data:{value:$v,source:"bootstrap-mamori"}}')" >/dev/null

log "Smoke: KV get ${SMOKE_PATH}"
got="$(BAO_TOKEN="$APP_TOKEN" bao_api GET "$SMOKE_PATH" | jq -r '.data.data.value')"
[[ "$got" == "$SMOKE_VALUE" ]] || die "KV round-trip failed (got='${got}' expected='${SMOKE_VALUE}')"
log "Smoke OK"

# --- write connection JSON (restore root token env not needed) ---
umask 077
jq -nc \
    --arg addr "$BAO_ADDR" \
    --arg auth "approle" \
    --arg role_id "$ROLE_ID" \
    --arg secret_id "$SECRET_ID" \
    --arg mount "$BAO_KV_MOUNT" \
    --arg policy "$BAO_POLICY_NAME" \
    --arg role "$BAO_ROLE_NAME" \
    --arg prefix "$BAO_SECRET_PREFIX" \
    --arg skip "$BAO_SKIP_VERIFY" \
    '{
      product: "OPENBAO",
      address: $addr,
      auth: $auth,
      role_id: $role_id,
      secret_id: $secret_id,
      mount: $mount,
      policy: $policy,
      role: $role,
      secret_prefix: $prefix,
      tls_skip_verify: ($skip == "1" or $skip == "true"),
      notes: "Store role_id/secret_id in Mamori SYS.INTEGRATIONS config_secret; do not commit this file."
    }' >"$OUT_FILE"
chmod 600 "$OUT_FILE"

log "Wrote connection file: $OUT_FILE"
echo
jq '{product,address,auth,role,mount,secret_prefix,tls_skip_verify,role_id,secret_id:("***"+(.secret_id[-4:]))}' "$OUT_FILE"
echo
echo "Mamori connection ready. Keep $OUT_FILE private."
