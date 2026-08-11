#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Install shared-cluster PostgreSQL 18 via the Docker Official Image, then
# initialize and check Mamori HA databases (init-ha-postgres.sh / check-ha-postgres.sh).
# Run on the dedicated Postgres host.
#
# Docs: https://doc.mamori.io/050-installation/ha-install
# Image: https://hub.docker.com/_/postgres

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER="${DOCKER:-docker}"
IMAGE="${IMAGE:-postgres:18}"
CONTAINER_NAME="${CONTAINER_NAME:-postgres}"
VOLUME_NAME="${VOLUME_NAME:-mamori-pg-data}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
FORCE=0
FORCE_VOLUME=0
WAIT_SECONDS="${WAIT_SECONDS:-60}"

usage() {
    cat <<'EOF'
Usage: install-ha-postgres.sh --password <secret> [options]

Pull and run official postgres:18 for Mamori HA, then initialize and check
databases mamorisys, audit, and xcs (via init-ha-postgres.sh / check-ha-postgres.sh).
Configures host SCRAM-SHA-256 auth for remote app-node connections.

Options:
  -p, --password <secret>   Superuser password (or set POSTGRES_PASSWORD)
  -n, --name <container>    Container name (default: postgres)
  -i, --image <image>       Image tag (default: postgres:18)
  -v, --volume <name>       Docker volume for data (default: mamori-pg-data)
      --port <port>         Host port published to 5432 (default: 5432)
      --user <user>         Superuser name (default: postgres)
  -f, --force               Replace an existing container with the same name
      --force-volume        With --force, also remove the data volume (DESTROYS DATA)
  -h, --help                Show this help

Environment:
  DOCKER                    Docker CLI (default: docker). Example: DOCKER="sudo docker"
  POSTGRES_PASSWORD         Alternative to --password
  WAIT_SECONDS              Seconds to wait for pg_isready (default: 60)

Examples:
  bash install-ha-postgres.sh --password 'choose-a-strong-password'
  bash install-ha-postgres.sh --password "$POSTGRES_PASSWORD" --port 5432
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--password)
            shift
            POSTGRES_PASSWORD="${1:-}"
            [[ -n "$POSTGRES_PASSWORD" ]] || { echo "Missing value for --password" >&2; exit 1; }
            ;;
        -n|--name)
            shift
            CONTAINER_NAME="${1:-}"
            [[ -n "$CONTAINER_NAME" ]] || { echo "Missing value for --name" >&2; exit 1; }
            ;;
        -i|--image)
            shift
            IMAGE="${1:-}"
            [[ -n "$IMAGE" ]] || { echo "Missing value for --image" >&2; exit 1; }
            ;;
        -v|--volume)
            shift
            VOLUME_NAME="${1:-}"
            [[ -n "$VOLUME_NAME" ]] || { echo "Missing value for --volume" >&2; exit 1; }
            ;;
        --port)
            shift
            PG_PORT="${1:-}"
            [[ -n "$PG_PORT" ]] || { echo "Missing value for --port" >&2; exit 1; }
            ;;
        --user)
            shift
            PG_USER="${1:-}"
            [[ -n "$PG_USER" ]] || { echo "Missing value for --user" >&2; exit 1; }
            ;;
        -f|--force)
            FORCE=1
            ;;
        --force-volume)
            FORCE_VOLUME=1
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

if [[ -z "$POSTGRES_PASSWORD" ]]; then
    echo "ERROR: --password or POSTGRES_PASSWORD is required" >&2
    usage >&2
    exit 1
fi

if ! command -v "$DOCKER" >/dev/null 2>&1 && [[ "$DOCKER" == "docker" ]]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: docker not found on PATH" >&2
        exit 1
    fi
fi

if ! $DOCKER info >/dev/null 2>&1; then
    echo "ERROR: cannot talk to Docker daemon (try DOCKER=\"sudo docker\")" >&2
    exit 1
fi

if $DOCKER inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    if [[ "$FORCE" -ne 1 ]]; then
        echo "ERROR: container '$CONTAINER_NAME' already exists (use --force to replace)" >&2
        exit 1
    fi
    echo "Removing existing container '$CONTAINER_NAME' ..."
    $DOCKER rm -f "$CONTAINER_NAME" >/dev/null
fi

if [[ "$FORCE_VOLUME" -eq 1 ]]; then
    if [[ "$FORCE" -ne 1 ]]; then
        echo "ERROR: --force-volume requires --force" >&2
        exit 1
    fi
    if $DOCKER volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
        echo "Removing volume '$VOLUME_NAME' (data will be destroyed) ..."
        $DOCKER volume rm "$VOLUME_NAME" >/dev/null
    fi
fi

echo "Pulling $IMAGE ..."
$DOCKER pull "$IMAGE"

echo "Creating and starting container '$CONTAINER_NAME' ..."
# PG 18+: mount at /var/lib/postgresql (not .../data).
# POSTGRES_HOST_AUTH_METHOD=scram-sha-256 matches Mamori HA docs (remote SCRAM-SHA-256 auth).
# password_encryption=scram-sha-256 stores passwords as SCRAM verifiers for that host auth.
$DOCKER run -d \
    --name "$CONTAINER_NAME" \
    --restart always \
    --log-opt max-size=10m --log-opt max-file=5 \
    -e "POSTGRES_USER=${PG_USER}" \
    -e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
    -e "POSTGRES_HOST_AUTH_METHOD=scram-sha-256" \
    -v "${VOLUME_NAME}:/var/lib/postgresql" \
    -p "${PG_PORT}:5432" \
    "$IMAGE" \
    -c password_encryption=scram-sha-256 \
    -c listen_addresses='*'

echo "Waiting for PostgreSQL to accept connections ..."
ready=0
for ((i = 1; i <= WAIT_SECONDS; i++)); do
    if $DOCKER exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CONTAINER_NAME" \
        pg_isready -U "$PG_USER" -h 127.0.0.1 >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done

if [[ "$ready" -ne 1 ]]; then
    echo "ERROR: PostgreSQL did not become ready within ${WAIT_SECONDS}s" >&2
    echo "Recent logs:" >&2
    $DOCKER logs --tail 50 "$CONTAINER_NAME" >&2 || true
    exit 1
fi

export DOCKER
echo ""
echo "Initializing Mamori databases ..."
bash "$SCRIPT_DIR/init-ha-postgres.sh" \
    --host 127.0.0.1 \
    --port "$PG_PORT" \
    --user "$PG_USER" \
    --password "$POSTGRES_PASSWORD" \
    --container "$CONTAINER_NAME"

echo ""
echo "Checking Mamori databases ..."
bash "$SCRIPT_DIR/check-ha-postgres.sh" \
    --host 127.0.0.1 \
    --port "$PG_PORT" \
    --user "$PG_USER" \
    --password "$POSTGRES_PASSWORD" \
    --container "$CONTAINER_NAME"

echo ""
echo "PostgreSQL HA shared database is ready."
echo "  container: $CONTAINER_NAME"
echo "  image:     $IMAGE"
echo "  volume:    $VOLUME_NAME -> /var/lib/postgresql"
echo "  port:      ${PG_PORT} (host) -> 5432"
echo "  user:      $PG_USER"
echo "  databases: mamorisys, audit, xcs"
echo ""
echo "Verify from an app-node host (firewall must allow ${PG_PORT}):"
echo "  PGPASSWORD='***' psql --host <this-host-ip> --port ${PG_PORT} -U ${PG_USER} -d mamorisys -c 'select version()'"
echo ""
echo "Next: install the first Mamori HA app node and join this Postgres instance."
echo "  See HA-README.md and https://doc.mamori.io/050-installation/ha-install"
