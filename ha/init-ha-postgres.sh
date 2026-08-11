#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Initialize an existing PostgreSQL instance for Mamori HA: create empty
# databases mamorisys, audit, and xcs when missing.
# Does not install Postgres or change pg_hba / listen_addresses.
#
# Docs: https://doc.mamori.io/050-installation/ha-install

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ha-pg-client.sh"

usage() {
    cat <<'EOF'
Usage: init-ha-postgres.sh --password <secret> [options]

Create Mamori HA databases (mamorisys, audit, xcs) on an existing Postgres
instance. Idempotent: skips databases that already exist.

Does not install PostgreSQL or configure remote auth. For the Docker
Postgres box, use install-ha-postgres.sh (it calls this script).

Options:
      --host <host>         Postgres host (default: 127.0.0.1)
      --port <port>         Postgres port (default: 5432)
      --user <user>         Superuser name (default: postgres)
  -p, --password <secret>   Password (or set PG_PASSWORD)
  -n, --container <name>    Use docker exec into this container instead of host psql
  -h, --help                Show this help

Environment:
  DOCKER                    Docker CLI when --container is set (default: docker)
  PG_HOST, PG_PORT, PG_USER, PG_PASSWORD

Examples:
  bash init-ha-postgres.sh --host 192.168.1.10 --password 'secret'
  bash init-ha-postgres.sh --password 'secret' --container postgres
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
rc=0
parse_ha_pg_args "$@" || rc=$?
if [[ $rc -ne 0 ]]; then
    usage >&2
    exit 1
fi

require_ha_pg_password || { usage >&2; exit 1; }

create_db_if_missing() {
    local db="$1"
    local exists
    exists="$(run_psql -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='${db}'")"
    if [[ "$exists" == "1" ]]; then
        echo "Database '$db' already exists"
    else
        echo "Creating database '$db' ..."
        run_psql -d postgres -c "CREATE DATABASE ${db};"
    fi
}

echo "Initializing Mamori HA databases on ${CONTAINER_NAME:+container $CONTAINER_NAME}${CONTAINER_NAME:-$PG_HOST:$PG_PORT} ..."
create_db_if_missing mamorisys
create_db_if_missing audit
create_db_if_missing xcs

echo ""
echo "Databases mamorisys, audit, and xcs are present."
echo "Remote SCRAM-SHA-256 auth, listen_addresses, and firewall must already allow app nodes."
echo "Next: bash check-ha-postgres.sh --host $PG_HOST --port $PG_PORT --user $PG_USER --password '***'"
