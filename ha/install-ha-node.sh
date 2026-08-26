#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Load HA cluster Docker media and create the mamori container (not started).
# Per https://doc.mamori.io/050-installation/ha-install
#
# Does not run join_cluster or docker start — those are separate steps.
#
# Role is determined by --env-file:
#   no --env-file  → first node: prompt PG_* + portal root, write env for join
#   --env-file     → additional node: never prompt; join applies DERBY_USER_ROOT

set -euo pipefail

DOCKER="${DOCKER:-docker}"
MEDIA="${MEDIA:-}"
CONTAINER_NAME="${CONTAINER_NAME:-mamori}"
IMAGE_NAME="${IMAGE_NAME:-mamori}"
FORCE=0
ENV_FILE=""
WRITE_ENV="/tmp/cluster-details.env"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ensure-mamori-root-password.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ensure-host-timezone.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ha-pg-schema-status.sh"

usage() {
    cat <<'EOF'
Usage: install-ha-node.sh [options]

Load mamori_cluster_docker.tgz and docker-create the HA app-node container.
Does not start the container or join the cluster.

Role (first vs additional node) is determined by --env-file:

  No --env-file (first node)
    Prompt for PG_HOST / PG_PORT / PG_USER / PG_PASSWORD and the portal root
    password (or use already-exported values). Verify mamorisys is unprimed.
    Write PG_* to --write-env (default /tmp/cluster-details.env) for join.
    Pass MAMORI_ROOT_PASSWORD into docker create when needed.

  --env-file <path> (additional node)
    Never prompt. Source PG_* (and DERBY_USER_ROOT) from the file (from
    extract-cluster-details.sh). Verify mamorisys is already primed.
    Do not pass MAMORI_ROOT_PASSWORD; join-ha-node.sh applies DERBY_USER_ROOT.

After create: bash join-ha-node.sh --env-file <path> && bash start-ha-node.sh

Options:
  -m, --media <file>     Path to cluster image tarball
                         (default: ./mamori_cluster_docker.tgz or /tmp/mamori_cluster_docker.tgz)
  -n, --name <name>      Container name (default: mamori)
  -i, --image <name>     Image name after load (default: mamori)
  -f, --force            Remove an existing stopped/created container with the same name
  -e, --env-file <path>  Additional node: cluster-details.env (never prompt)
  -o, --write-env <path> First node: where to write prompted PG_* (default: /tmp/cluster-details.env)
  -h, --help             Show this help

Environment:
  DOCKER                 Docker CLI (default: docker). Example: DOCKER="sudo docker"
  PG_HOST, PG_PORT, PG_USER, PG_PASSWORD
                         First node: skip prompts when already set
  MAMORI_ROOT_PASSWORD   First node only: skip root prompt when already set
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--media)
            shift
            MEDIA="${1:-}"
            [[ -n "$MEDIA" ]] || { echo "Missing value for --media" >&2; exit 1; }
            ;;
        -n|--name)
            shift
            CONTAINER_NAME="${1:-}"
            [[ -n "$CONTAINER_NAME" ]] || { echo "Missing value for --name" >&2; exit 1; }
            ;;
        -i|--image)
            shift
            IMAGE_NAME="${1:-}"
            [[ -n "$IMAGE_NAME" ]] || { echo "Missing value for --image" >&2; exit 1; }
            ;;
        -f|--force)
            FORCE=1
            ;;
        -e|--env-file)
            shift
            ENV_FILE="${1:-}"
            [[ -n "$ENV_FILE" ]] || { echo "Missing value for --env-file" >&2; exit 1; }
            ;;
        -o|--write-env)
            shift
            WRITE_ENV="${1:-}"
            [[ -n "$WRITE_ENV" ]] || { echo "Missing value for --write-env" >&2; exit 1; }
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

resolve_media() {
    if [[ -n "$MEDIA" ]]; then
        printf '%s' "$MEDIA"
        return 0
    fi
    if [[ -f ./mamori_cluster_docker.tgz ]]; then
        printf '%s' ./mamori_cluster_docker.tgz
        return 0
    fi
    if [[ -f /tmp/mamori_cluster_docker.tgz ]]; then
        printf '%s' /tmp/mamori_cluster_docker.tgz
        return 0
    fi
    if [[ -f ./mamori_docker.tgz ]]; then
        printf '%s' ./mamori_docker.tgz
        return 0
    fi
    if [[ -f /tmp/mamori_docker.tgz ]]; then
        printf '%s' /tmp/mamori_docker.tgz
        return 0
    fi
    return 1
}

prompt_pg_value() {
    local var_name="$1" prompt_label="$2" default_val="${3-}" secret="${4:-0}"
    local current="${!var_name-}" input
    if [[ -n "$current" ]]; then
        echo "$var_name is set; using existing value." >&2
        return 0
    fi
    if [[ ! -t 0 ]]; then
        echo "ERROR: $var_name is required but not set, and stdin is not a TTY." >&2
        echo "Export $var_name or re-run from an interactive terminal." >&2
        return 1
    fi
    if [[ "$secret" == "1" ]]; then
        if [[ -n "$default_val" ]]; then
            read -r -s -p "${prompt_label} [${default_val}]: " input >&2
        else
            read -r -s -p "${prompt_label}: " input >&2
        fi
        echo >&2
    else
        if [[ -n "$default_val" ]]; then
            read -r -p "${prompt_label} [${default_val}]: " input >&2
        else
            read -r -p "${prompt_label}: " input >&2
        fi
    fi
    if [[ -z "$input" ]]; then
        input="$default_val"
    fi
    if [[ -z "$input" ]]; then
        echo "ERROR: $var_name must not be empty." >&2
        return 1
    fi
    printf -v "$var_name" '%s' "$input"
    export "$var_name"
}

escape_env() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_first_node_env() {
    local out="$1"
    umask 077
    {
        echo "# Generated by install-ha-node.sh (first node) on $(hostname) at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Use: bash join-ha-node.sh --env-file $out"
        echo
        printf 'PG_HOST="%s"\n' "$(escape_env "$PG_HOST")"
        printf 'PG_PORT="%s"\n' "$(escape_env "$PG_PORT")"
        printf 'PG_USER="%s"\n' "$(escape_env "$PG_USER")"
        printf 'PG_PASSWORD="%s"\n' "$(escape_env "$PG_PASSWORD")"
    } >"$out"
    chmod 600 "$out"
    echo "Wrote $out (mode 0600) for join-ha-node.sh." >&2
}

require_pg_vars() {
    local missing=0
    for v in PG_HOST PG_PORT PG_USER PG_PASSWORD; do
        if [[ -z "${!v:-}" ]]; then
            echo "ERROR: $v is missing or empty" >&2
            missing=1
        fi
    done
    [[ "$missing" -eq 0 ]] || return 1
}

TZ_VALUE="$(host_timezone_for_container)"

if ! command -v "${DOCKER%% *}" >/dev/null 2>&1 && ! $DOCKER version >/dev/null 2>&1; then
    echo "ERROR: docker not available (DOCKER='$DOCKER')" >&2
    exit 1
fi

if ! MEDIA_FILE="$(resolve_media)"; then
    echo "ERROR: cluster media tarball not found." >&2
    echo "Run get-ha-media.sh first, or pass --media /path/to/mamori_cluster_docker.tgz" >&2
    exit 1
fi

if [[ ! -f "$MEDIA_FILE" ]]; then
    echo "ERROR: media file not found: $MEDIA_FILE" >&2
    exit 1
fi

JOIN_ENV_PATH=""
if [[ -n "$ENV_FILE" ]]; then
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "ERROR: env file not found: $ENV_FILE" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a
    require_pg_vars || exit 1
    JOIN_ENV_PATH="$ENV_FILE"

    echo "HA node install (load + create)"
    echo "  media:     $MEDIA_FILE"
    echo "  image:     $IMAGE_NAME"
    echo "  container: $CONTAINER_NAME"
    echo "  TZ:        $TZ_VALUE"
    echo "  role:      additional node (--env-file; no prompts)"
    echo "  env file:  $ENV_FILE"
    echo ""

    ha_pg_require_primed || exit 1
    if [[ -z "${DERBY_USER_ROOT:-}" || "${DERBY_USER_ROOT}" == "REPLACEME" ]]; then
        echo "WARNING: DERBY_USER_ROOT is not set in $ENV_FILE" >&2
        echo "         join-ha-node.sh needs it from extract-cluster-details.sh." >&2
    fi
    export MAMORI_ROOT_PASSWORD_REQUIRED=0
else
    echo "HA node install (load + create)"
    echo "  media:     $MEDIA_FILE"
    echo "  image:     $IMAGE_NAME"
    echo "  container: $CONTAINER_NAME"
    echo "  TZ:        $TZ_VALUE"
    echo "  role:      first node (prompt PG_* + portal root)"
    echo ""

    prompt_pg_value PG_HOST "Postgres host" "" 0 || exit 1
    prompt_pg_value PG_PORT "Postgres port" "5432" 0 || exit 1
    prompt_pg_value PG_USER "Postgres user" "postgres" 0 || exit 1
    prompt_pg_value PG_PASSWORD "Postgres password" "" 1 || exit 1
    export PG_HOST PG_PORT PG_USER PG_PASSWORD

    ha_pg_require_unprimed || exit 1

    export DOCKER
    ensure_mamori_root_password

    write_first_node_env "$WRITE_ENV"
    JOIN_ENV_PATH="$WRITE_ENV"
fi

if $DOCKER inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    STATUS="$($DOCKER inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"
    if [[ "$FORCE" -eq 1 ]]; then
        echo "Removing existing container $CONTAINER_NAME (status=$STATUS)"
        $DOCKER rm -f "$CONTAINER_NAME" >/dev/null
    else
        echo "ERROR: container '$CONTAINER_NAME' already exists (status=$STATUS)." >&2
        echo "Stop/remove it, or re-run with --force." >&2
        exit 1
    fi
fi

echo "Loading image from $MEDIA_FILE ..."
$DOCKER load < "$MEDIA_FILE"

echo "Creating container $CONTAINER_NAME ..."
CREATE_ARGS=(
        --network host
        --restart always
        --privileged
        --log-opt max-size=10m --log-opt max-file=10
        -v /var/run/docker.sock:/var/run/docker.sock
        -v mamori-var:/opt/mamori/var
        -v mamori-nginx-conf:/etc/nginx
        -v /proc:/host/proc:ro
        -e "TZ=${TZ_VALUE}"
        --name "$CONTAINER_NAME"
)
if [[ "${MAMORI_ROOT_PASSWORD_REQUIRED:-0}" == "1" ]]; then
    CREATE_ARGS+=(-e "MAMORI_ROOT_PASSWORD=${MAMORI_ROOT_PASSWORD}")
fi

$DOCKER create "${CREATE_ARGS[@]}" "$IMAGE_NAME" /sbin/my_init

echo ""
echo "Created container '$CONTAINER_NAME' (not started)."
echo "Next steps:"
echo "  1. bash join-ha-node.sh --env-file $JOIN_ENV_PATH"
echo "  2. bash start-ha-node.sh"
unset MAMORI_ROOT_PASSWORD 2>/dev/null || true
unset PG_PASSWORD 2>/dev/null || true
