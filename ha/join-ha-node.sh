#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Join this HA app node to the shared cluster Postgres using details from
# extract-cluster-details.sh (cluster-details.env).
# Per https://doc.mamori.io/050-installation/ha-install
#
# Run after install-ha-node.sh (container created) and before docker start.
# Passes PG_* / MAMORI_ENCRYPTION_KEY into a temporary container via env
# (avoids join_cluster.sh CLI flag quirks for --pg-port / --pg-user).

set -euo pipefail

DOCKER="${DOCKER:-docker}"
ENV_FILE=""
CONTAINER_NAME="${CONTAINER_NAME:-mamori}"
IMAGE_NAME="${IMAGE_NAME:-mamori}"

usage() {
    cat <<'EOF'
Usage: join-ha-node.sh --env-file <cluster-details.env> [options]

Configure the created (not yet started) mamori container to use the shared
cluster database, using an env file from extract-cluster-details.sh.

Required env file keys:
  PG_HOST, PG_PORT, PG_USER, PG_PASSWORD
Recommended:
  MAMORI_ENCRYPTION_KEY

Options:
  -e, --env-file <file>   Path to cluster-details.env (required)
  -n, --name <name>       Container to take volumes from (default: mamori)
  -i, --image <name>      Image for the join helper container (default: mamori)
  -h, --help              Show this help

Environment:
  DOCKER                  Docker CLI (default: docker). Example: DOCKER="sudo docker"

Example:
  # on m1:
  bash extract-cluster-details.sh -o /tmp/cluster-details.env
  # copy env to new node, then:
  bash join-ha-node.sh --env-file /tmp/cluster-details.env
  docker start mamori
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--env-file)
            shift
            ENV_FILE="${1:-}"
            [[ -n "$ENV_FILE" ]] || { echo "Missing value for --env-file" >&2; exit 1; }
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

if [[ -z "$ENV_FILE" ]]; then
    echo "ERROR: --env-file is required" >&2
    usage >&2
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: env file not found: $ENV_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

require_var() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "ERROR: $name is missing or empty in $ENV_FILE" >&2
        exit 1
    fi
}

require_var PG_HOST
require_var PG_PORT
require_var PG_USER
require_var PG_PASSWORD

if [[ -z "${MAMORI_ENCRYPTION_KEY:-}" ]]; then
    echo "WARNING: MAMORI_ENCRYPTION_KEY is not set — node may not share encryption with the cluster" >&2
fi

if ! $DOCKER inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "ERROR: container '$CONTAINER_NAME' not found. Run install-ha-node.sh first." >&2
    exit 1
fi

STATUS="$($DOCKER inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"
if [[ "$STATUS" == "running" ]]; then
    echo "WARNING: container '$CONTAINER_NAME' is already running. Join normally runs before first start." >&2
fi

echo "Joining HA cluster via shared Postgres"
echo "  env file:  $ENV_FILE"
echo "  container: $CONTAINER_NAME (volumes-from)"
echo "  image:     $IMAGE_NAME"
echo "  PG:        ${PG_USER}@${PG_HOST}:${PG_PORT}"
echo ""

# Pass credentials as container env and invoke join_cluster.sh with no CLI flags.
# Upstream join_cluster.sh mishandles --pg-port / --pg-user; env vars are honored.
JOIN_ARGS=(
    run --rm
    --volumes-from "$CONTAINER_NAME"
    -e "PG_HOST=${PG_HOST}"
    -e "PG_PORT=${PG_PORT}"
    -e "PG_USER=${PG_USER}"
    -e "PG_PASSWORD=${PG_PASSWORD}"
)

if [[ -n "${MAMORI_ENCRYPTION_KEY:-}" ]]; then
    JOIN_ARGS+=(-e "MAMORI_ENCRYPTION_KEY=${MAMORI_ENCRYPTION_KEY}")
fi

JOIN_ARGS+=("$IMAGE_NAME" /opt/mamori/mamori/bin/join_cluster.sh)

$DOCKER "${JOIN_ARGS[@]}"

echo ""
echo "Join configuration applied to volumes for '$CONTAINER_NAME'."
echo "Next: $DOCKER start $CONTAINER_NAME"
echo "      $DOCKER exec -it $CONTAINER_NAME tail -F /opt/mamori/var/log/mamori_fqod.log"
