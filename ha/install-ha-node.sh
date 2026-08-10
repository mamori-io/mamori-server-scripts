#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Load HA cluster Docker media and create the mamori container (not started).
# Per https://doc.mamori.io/050-installation/ha-install
#
# Does not run join_cluster or docker start — those are separate steps.

set -euo pipefail

DOCKER="${DOCKER:-docker}"
MEDIA="${MEDIA:-}"
CONTAINER_NAME="${CONTAINER_NAME:-mamori}"
IMAGE_NAME="${IMAGE_NAME:-mamori}"
FORCE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ensure-mamori-root-password.sh"

usage() {
    cat <<'EOF'
Usage: install-ha-node.sh [options]

Load mamori_cluster_docker.tgz and docker-create the HA app-node container.
Does not start the container or join the cluster.

On a fresh mamori-var volume, prompts for (or uses) MAMORI_ROOT_PASSWORD and
passes it into docker create for first-boot bootstrap. After docker start,
run: bash ../lib/scrub-mamori-root-password-env.sh  (or ha/start-ha-node.sh)

Options:
  -m, --media <file>     Path to cluster image tarball
                         (default: ./mamori_cluster_docker.tgz or /tmp/mamori_cluster_docker.tgz)
  -n, --name <name>      Container name (default: mamori)
  -i, --image <name>     Image name after load (default: mamori)
  -f, --force            Remove an existing stopped/created container with the same name
  -h, --help             Show this help

Environment:
  DOCKER                 Docker CLI (default: docker). Example: DOCKER="sudo docker"
  MAMORI_ROOT_PASSWORD   Portal root password for first boot (prompted if required)
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
    # Accept alternate local name used in some curl examples
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

resolve_tz() {
    if [[ -f /etc/timezone ]]; then
        tr -d '[:space:]' < /etc/timezone
        return 0
    fi
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl show -p Timezone --value 2>/dev/null && return 0
    fi
    printf '%s' "Etc/UTC"
}

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

TZ_VALUE="$(resolve_tz)"

echo "HA node install (load + create)"
echo "  media:     $MEDIA_FILE"
echo "  image:     $IMAGE_NAME"
echo "  container: $CONTAINER_NAME"
echo "  TZ:        $TZ_VALUE"
echo ""

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

export DOCKER
ensure_mamori_root_password

echo "Creating container $CONTAINER_NAME ..."
# Volumes match HA install docs (no local postgres/influx/grafana volumes).
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
echo "Next steps per HA docs:"
echo "  1. join shared DB:  bash join-ha-node.sh ..."
echo "  2. start + scrub:   bash start-ha-node.sh"
unset MAMORI_ROOT_PASSWORD 2>/dev/null || true
