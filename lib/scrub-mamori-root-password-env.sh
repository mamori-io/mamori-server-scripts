#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# After first boot has stored derby.user.root, recreate the container without
# MAMORI_ROOT_PASSWORD so the secret is not left on the container config
# (docker inspect). Also removes a legacy host .mamori-root-password.env if present.
#
# Usage: scrub-mamori-root-password-env.sh [--name mamori] [--wait-seconds 180]

set -euo pipefail

DOCKER="${DOCKER:-docker}"
CONTAINER_NAME="${CONTAINER_NAME:-mamori}"
MAMORI_VAR_VOLUME="${MAMORI_VAR_VOLUME:-mamori-var}"
WAIT_SECONDS="${WAIT_SECONDS:-180}"

# Legacy path from older scripts that wrote a host env file (best-effort cleanup).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
MAMORI_ROOT_PASSWORD_ENV_FILE="${MAMORI_ROOT_PASSWORD_ENV_FILE:-$_REPO_ROOT/.mamori-root-password.env}"

usage() {
    cat <<'EOF'
Usage: scrub-mamori-root-password-env.sh [options]

Recreate the Mamori container without MAMORI_ROOT_PASSWORD after bootstrap.

Options:
  -n, --name <container>   Container name (default: mamori)
      --wait-seconds <n>   Wait for derby.user.root on volume (default: 180)
  -h, --help               Show this help

Environment:
  DOCKER                   Docker CLI (default: docker)
  MAMORI_VAR_VOLUME        Volume name (default: mamori-var)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)
            shift
            CONTAINER_NAME="${1:-}"
            [[ -n "$CONTAINER_NAME" ]] || { echo "Missing value for --name" >&2; exit 1; }
            ;;
        --wait-seconds)
            shift
            WAIT_SECONDS="${1:-}"
            [[ -n "$WAIT_SECONDS" ]] || { echo "Missing value for --wait-seconds" >&2; exit 1; }
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

if ! $DOCKER inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "ERROR: container '$CONTAINER_NAME' not found" >&2
    exit 1
fi

has_root_env=0
if $DOCKER inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" | grep -q '^MAMORI_ROOT_PASSWORD='; then
    has_root_env=1
fi

if [[ "$has_root_env" -ne 1 ]]; then
    echo "Container '$CONTAINER_NAME' has no MAMORI_ROOT_PASSWORD env; nothing to scrub."
    rm -f "$MAMORI_ROOT_PASSWORD_ENV_FILE"
    exit 0
fi

host_path="$($DOCKER volume inspect -f '{{.Mountpoint}}' "$MAMORI_VAR_VOLUME" 2>/dev/null || true)"
if [[ -z "$host_path" ]]; then
    echo "ERROR: volume '$MAMORI_VAR_VOLUME' not found" >&2
    exit 1
fi

echo "Waiting up to ${WAIT_SECONDS}s for derby.user.root on $MAMORI_VAR_VOLUME ..."
ready=0
for ((i = 1; i <= WAIT_SECONDS; i++)); do
    val=""
    if [[ -f "$host_path/derby.properties" ]]; then
        val="$(sed -n 's/^derby\.user\.root=//p' "$host_path/derby.properties" | head -1)"
    fi
    if [[ -n "$val" && "$val" != "REPLACEME" ]]; then
        ready=1
        break
    fi
    sleep 1
done

if [[ "$ready" -ne 1 ]]; then
    echo "ERROR: derby.user.root not set within ${WAIT_SECONDS}s; not scrubbing env (check container logs)." >&2
    exit 1
fi

echo "Portal root password is stored. Recreating '$CONTAINER_NAME' without MAMORI_ROOT_PASSWORD ..."

IMAGE="$($DOCKER inspect -f '{{.Config.Image}}' "$CONTAINER_NAME")"
NETWORK="$($DOCKER inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME")"
PRIVILEGED="$($DOCKER inspect -f '{{.HostConfig.Privileged}}' "$CONTAINER_NAME")"
RESTART="$($DOCKER inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER_NAME")"
RESTART_RETRIES="$($DOCKER inspect -f '{{.HostConfig.RestartPolicy.MaximumRetryCount}}' "$CONTAINER_NAME")"

# Cmd as words (typically /sbin/my_init).
# println leaves a trailing blank line; mapfile would keep "" and docker create
# would set Cmd=["/sbin/my_init",""], which crashes my_init:
#   ValueError: argv first element cannot be empty
mapfile -t CMD_ARR < <($DOCKER inspect -f '{{range .Config.Cmd}}{{println .}}{{end}}' "$CONTAINER_NAME")
# Drop empty words from trailing newlines
_tmp_cmd=()
for _c in "${CMD_ARR[@]}"; do
    [[ -n "$_c" ]] && _tmp_cmd+=("$_c")
done
CMD_ARR=("${_tmp_cmd[@]}")
unset _tmp_cmd _c
if [[ ${#CMD_ARR[@]} -eq 0 ]]; then
    CMD_ARR=(/sbin/my_init)
fi
# #region agent log
if [[ -n "${MAMORI_DEBUG_LOG:-}" ]]; then
    _cmd_json="["
    _first=1
    for _c in "${CMD_ARR[@]}"; do
        [[ $_first -eq 1 ]] && _first=0 || _cmd_json+=","
        _cmd_json+="\"${_c//\"/\\\"}\""
    done
    _cmd_json+="]"
    printf '%s\n' "{\"sessionId\":\"57422e\",\"hypothesisId\":\"A\",\"location\":\"scrub-mamori-root-password-env.sh:cmd\",\"message\":\"scrub cmd after filter\",\"data\":{\"cmd\":${_cmd_json}},\"timestamp\":$(($(date +%s)*1000))}" >>"$MAMORI_DEBUG_LOG" || true
    unset _cmd_json _first _c
fi
# #endregion

CREATE_ARGS=(--name "$CONTAINER_NAME")
[[ "$NETWORK" == "host" ]] && CREATE_ARGS+=(--network host)
[[ "$PRIVILEGED" == "true" ]] && CREATE_ARGS+=(--privileged)
if [[ -n "$RESTART" && "$RESTART" != "no" ]]; then
    if [[ "$RESTART" == "on-failure" && "${RESTART_RETRIES:-0}" -gt 0 ]]; then
        CREATE_ARGS+=(--restart "on-failure:${RESTART_RETRIES}")
    else
        CREATE_ARGS+=(--restart "$RESTART")
    fi
fi

# Preserve log opts when present
LOG_MAX_SIZE="$($DOCKER inspect -f '{{index .HostConfig.LogConfig.Config "max-size"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
LOG_MAX_FILE="$($DOCKER inspect -f '{{index .HostConfig.LogConfig.Config "max-file"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
[[ -n "$LOG_MAX_SIZE" && "$LOG_MAX_SIZE" != "<no value>" ]] && CREATE_ARGS+=(--log-opt "max-size=${LOG_MAX_SIZE}")
[[ -n "$LOG_MAX_FILE" && "$LOG_MAX_FILE" != "<no value>" ]] && CREATE_ARGS+=(--log-opt "max-file=${LOG_MAX_FILE}")

# Mounts — use ASCII RS (0x1e) separators and never-empty placeholders.
# Bash 5.3+ collapses consecutive IFS tab delimiters, which breaks bind mounts
# that have an empty .Name (e.g. /proc:/host/proc:ro → invalid /host/proc:ro).
while IFS=$'\x1e' read -r mtype mname msrc mdest mmode; do
    [[ -z "${mdest:-}" || "$mdest" == "-" ]] && continue
    [[ "$mname" == "-" ]] && mname=""
    [[ "$msrc" == "-" ]] && msrc=""
    [[ "$mmode" == "-" ]] && mmode=""
    if [[ "$mtype" == "volume" && -n "$mname" ]]; then
        CREATE_ARGS+=(-v "${mname}:${mdest}")
    elif [[ "$mtype" == "bind" && -n "$msrc" ]]; then
        if [[ -n "$mmode" ]]; then
            CREATE_ARGS+=(-v "${msrc}:${mdest}:${mmode}")
        else
            CREATE_ARGS+=(-v "${msrc}:${mdest}")
        fi
    fi
done < <($DOCKER inspect -f '{{range .Mounts}}{{.Type}}{{"\x1e"}}{{if .Name}}{{.Name}}{{else}}-{{end}}{{"\x1e"}}{{if .Source}}{{.Source}}{{else}}-{{end}}{{"\x1e"}}{{.Destination}}{{"\x1e"}}{{if .Mode}}{{.Mode}}{{else}}-{{end}}{{"\n"}}{{end}}' "$CONTAINER_NAME")

# Env except MAMORI_ROOT_PASSWORD
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == MAMORI_ROOT_PASSWORD=* ]] && continue
    CREATE_ARGS+=(-e "$line")
done < <($DOCKER inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME")

$DOCKER stop "$CONTAINER_NAME" >/dev/null
$DOCKER rm "$CONTAINER_NAME" >/dev/null

$DOCKER create "${CREATE_ARGS[@]}" "$IMAGE" "${CMD_ARR[@]}"
$DOCKER start "$CONTAINER_NAME" >/dev/null

rm -f "$MAMORI_ROOT_PASSWORD_ENV_FILE"
unset MAMORI_ROOT_PASSWORD 2>/dev/null || true

echo "Recreated and started '$CONTAINER_NAME' without MAMORI_ROOT_PASSWORD."
