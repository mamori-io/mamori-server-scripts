#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Verify an existing PostgreSQL instance is initialized for Mamori HA:
# reachable, and databases mamorisys, audit, and xcs exist.
#
# Docs: https://doc.mamori.io/050-installation/ha-install

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ha-pg-client.sh"

FAILS=0
WARNS=0
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

usage() {
    cat <<'EOF'
Usage: check-ha-postgres.sh --password <secret> [options]

Check that Postgres is reachable and Mamori HA databases exist
(mamorisys, audit, xcs). Does not create databases (see init-ha-postgres.sh).

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

Exit 0 only if connect works and all three databases exist.
EOF
}

pass() { echo -e "${GREEN}[PASS]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; FAILS=$((FAILS + 1)); }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; WARNS=$((WARNS + 1)); }

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

echo "=== Mamori HA Postgres check ==="
if [[ -n "$CONTAINER_NAME" ]]; then
    echo "  container: $CONTAINER_NAME"
else
    echo "  host: $PG_HOST  port: $PG_PORT"
fi
echo "  user: $PG_USER"
echo ""

echo "--- Connectivity ---"
set +e
ver="$(run_psql -d postgres -Atqc 'SELECT version()' 2>/tmp/ha-pg-check.err)"
conn_rc=$?
set -e
if [[ $conn_rc -eq 0 && -n "$ver" ]]; then
    pass "Connected"
    echo "       $ver"
else
    fail "Cannot connect to PostgreSQL"
    [[ -s /tmp/ha-pg-check.err ]] && echo "       $(head -3 /tmp/ha-pg-check.err)"
    echo ""
    echo "RESULT: NOT READY — cannot connect"
    exit 1
fi
echo ""

echo "--- Databases ---"
missing=0
for db in mamorisys audit xcs; do
    exists="$(run_psql -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='${db}'")"
    if [[ "$exists" == "1" ]]; then
        pass "Database '$db' exists"
    else
        fail "Database '$db' is missing"
        missing=1
    fi
done
if [[ "$missing" -eq 1 ]]; then
    echo "       Run: bash init-ha-postgres.sh --host $PG_HOST --port $PG_PORT --user $PG_USER --password '***'"
fi
echo ""

echo "--- Auth ---"
enc="$(run_psql -d postgres -Atqc 'SHOW password_encryption' 2>/dev/null || true)"
if [[ "$enc" == "scram-sha-256" ]]; then
    pass "password_encryption is scram-sha-256"
elif [[ -n "$enc" ]]; then
    warn "password_encryption is '$enc' (Mamori HA docs recommend scram-sha-256)"
else
    warn "Could not read password_encryption"
fi
echo ""

echo "===================================================="
if [[ "$FAILS" -eq 0 ]]; then
    echo -e "${GREEN}RESULT: READY${RESET} — Postgres is initialized for Mamori HA (${WARNS} warning(s))"
    echo "===================================================="
    exit 0
else
    echo -e "${RED}RESULT: NOT READY${RESET} — ${FAILS} failure(s), ${WARNS} warning(s)"
    echo "===================================================="
    exit 1
fi
