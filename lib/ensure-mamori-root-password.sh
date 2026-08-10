# Ensure MAMORI_ROOT_PASSWORD is available when a fresh mamori-var needs
# portal root bootstrap. Safe to source or execute.
#
# If derby.user.root is already set on the mamori-var volume, password is
# not required and this script leaves MAMORI_ROOT_PASSWORD unchanged
# (callers should not pass it to docker create).
#
# If required and unset: prompt (or fail if non-interactive), export
# MAMORI_ROOT_PASSWORD, and write .mamori-root-password.env (mode 0600).
#
# Environment:
#   DOCKER                 Docker/Podman CLI (default: docker)
#   MAMORI_VAR_VOLUME      Volume name (default: mamori-var)
#   MAMORI_ROOT_PASSWORD   May already be set by the operator
#   MAMORI_ROOT_PASSWORD_ENV_FILE  Override path for the env file
#
# Sets (when sourced):
#   MAMORI_ROOT_PASSWORD
#   MAMORI_ROOT_PASSWORD_REQUIRED=0|1

DOCKER="${DOCKER:-docker}"
MAMORI_VAR_VOLUME="${MAMORI_VAR_VOLUME:-mamori-var}"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
MAMORI_ROOT_PASSWORD_ENV_FILE="${MAMORI_ROOT_PASSWORD_ENV_FILE:-$_REPO_ROOT/.mamori-root-password.env}"

mamori_root_password_value_from_props() {
    local props="$1"
    [[ -f "$props" ]] || return 0
    sed -n 's/^derby\.user\.root=//p' "$props" | head -1
}

mamori_root_password_is_unset() {
    local val="${1:-}"
    [[ -z "$val" || "$val" == "REPLACEME" ]]
}

mamori_var_host_path() {
    local mount
    mount="$($DOCKER volume inspect -f '{{.Mountpoint}}' "$MAMORI_VAR_VOLUME" 2>/dev/null || true)"
    if [[ -n "$mount" && -d "$mount" ]]; then
        printf '%s' "$mount"
        return 0
    fi
    return 1
}

# Returns 0 if bootstrap env is required (no usable derby.user.root yet).
mamori_root_password_required() {
    local host_path props val
    if ! host_path="$(mamori_var_host_path)"; then
        # Volume does not exist yet — fresh install needs bootstrap.
        return 0
    fi
    props="$host_path/derby.properties"
    if [[ ! -f "$props" ]]; then
        return 0
    fi
    val="$(mamori_root_password_value_from_props "$props")"
    if mamori_root_password_is_unset "$val"; then
        return 0
    fi
    return 1
}

prompt_mamori_root_password() {
    local p1 p2
    if [[ ! -t 0 ]]; then
        echo "ERROR: MAMORI_ROOT_PASSWORD is required but not set, and stdin is not a TTY." >&2
        echo "Export MAMORI_ROOT_PASSWORD or re-run from an interactive terminal." >&2
        return 1
    fi
    while true; do
        echo "Set the Mamori portal root user password (stored encrypted on first container start)." >&2
        read -r -s -p "Portal root password: " p1 >&2
        echo >&2
        if [[ -z "$p1" ]]; then
            echo "Password must not be empty." >&2
            continue
        fi
        read -r -s -p "Retype password: " p2 >&2
        echo >&2
        if [[ "$p1" != "$p2" ]]; then
            echo "Passwords do not match." >&2
            continue
        fi
        printf '%s' "$p1"
        return 0
    done
}

write_mamori_root_password_env_file() {
    local pw="$1"
    umask 077
    printf 'MAMORI_ROOT_PASSWORD=%s\n' "$pw" >"$MAMORI_ROOT_PASSWORD_ENV_FILE"
    chmod 600 "$MAMORI_ROOT_PASSWORD_ENV_FILE"
    echo "Wrote $MAMORI_ROOT_PASSWORD_ENV_FILE (mode 0600). Delete after successful first start." >&2
}

ensure_mamori_root_password() {
    # Load from env file if present and shell env empty
    if [[ -z "${MAMORI_ROOT_PASSWORD:-}" && -f "$MAMORI_ROOT_PASSWORD_ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        set -a
        # shellcheck disable=SC1091
        . "$MAMORI_ROOT_PASSWORD_ENV_FILE"
        set +a
    fi

    if ! mamori_root_password_required; then
        export MAMORI_ROOT_PASSWORD_REQUIRED=0
        echo "Portal root password already present on volume '$MAMORI_VAR_VOLUME'; bootstrap env not required." >&2
        return 0
    fi

    export MAMORI_ROOT_PASSWORD_REQUIRED=1

    if [[ -n "${MAMORI_ROOT_PASSWORD:-}" ]]; then
        echo "MAMORI_ROOT_PASSWORD is set; will pass to container for first-boot bootstrap." >&2
        write_mamori_root_password_env_file "$MAMORI_ROOT_PASSWORD"
        export MAMORI_ROOT_PASSWORD
        return 0
    fi

    MAMORI_ROOT_PASSWORD="$(prompt_mamori_root_password)"
    export MAMORI_ROOT_PASSWORD
    write_mamori_root_password_env_file "$MAMORI_ROOT_PASSWORD"
}

# When executed (not sourced), run ensure.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    ensure_mamori_root_password
    if [[ "${MAMORI_ROOT_PASSWORD_REQUIRED:-0}" == "1" ]]; then
        echo "OK: MAMORI_ROOT_PASSWORD ready (required=1). Source this script or the env file from install scripts." >&2
    else
        echo "OK: bootstrap not required (required=0)." >&2
    fi
fi
