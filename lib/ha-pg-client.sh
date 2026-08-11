# Mamori LLC copyright 2026.
#
# Shared Postgres client for HA init/check scripts. Source this file.
# Uses docker exec when CONTAINER_NAME is set; otherwise host psql to PG_HOST:PG_PORT.

DOCKER="${DOCKER:-docker}"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-postgres}"
PG_PASSWORD="${PG_PASSWORD:-}"
CONTAINER_NAME="${CONTAINER_NAME:-}"

parse_ha_pg_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                shift
                PG_HOST="${1:-}"
                [[ -n "$PG_HOST" ]] || { echo "Missing value for --host" >&2; return 1; }
                ;;
            --port)
                shift
                PG_PORT="${1:-}"
                [[ -n "$PG_PORT" ]] || { echo "Missing value for --port" >&2; return 1; }
                ;;
            --user)
                shift
                PG_USER="${1:-}"
                [[ -n "$PG_USER" ]] || { echo "Missing value for --user" >&2; return 1; }
                ;;
            -p|--password)
                shift
                PG_PASSWORD="${1:-}"
                [[ -n "$PG_PASSWORD" ]] || { echo "Missing value for --password" >&2; return 1; }
                ;;
            -n|--container|--name)
                shift
                CONTAINER_NAME="${1:-}"
                [[ -n "$CONTAINER_NAME" ]] || { echo "Missing value for --container" >&2; return 1; }
                ;;
            *)
                echo "Unknown option: $1" >&2
                return 2
                ;;
        esac
        shift
    done
}

require_ha_pg_password() {
    if [[ -z "$PG_PASSWORD" ]]; then
        echo "ERROR: --password or PG_PASSWORD is required" >&2
        return 1
    fi
}

# run_psql [psql args...]
# Connection flags are injected; remaining args are passed through.
run_psql() {
    if [[ -n "$CONTAINER_NAME" ]]; then
        if ! command -v "${DOCKER%% *}" >/dev/null 2>&1 && ! $DOCKER version >/dev/null 2>&1; then
            echo "ERROR: docker not available (DOCKER='$DOCKER')" >&2
            return 1
        fi
        $DOCKER exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            psql -U "$PG_USER" -h 127.0.0.1 -p 5432 "$@"
    else
        if ! command -v psql >/dev/null 2>&1; then
            echo "ERROR: psql not found on PATH (install postgresql-client, or pass --container)" >&2
            return 1
        fi
        PGPASSWORD="$PG_PASSWORD" psql --host "$PG_HOST" --port "$PG_PORT" -U "$PG_USER" "$@"
    fi
}
