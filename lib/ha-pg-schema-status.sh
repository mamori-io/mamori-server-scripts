# Mamori LLC copyright 2026.
#
# HA Postgres schema status helpers. Source after PG_HOST/PG_PORT/PG_USER/PG_PASSWORD
# are set. Uses host psql (postgresql-client required on the app-node host).
#
# Sets:
#   HA_PG_SCHEMA_PRIMED=0|1
#
# Functions:
#   ha_pg_schema_is_primed   — probe mamorisys; set HA_PG_SCHEMA_PRIMED
#   ha_pg_require_unprimed   — first node: fail if already primed
#   ha_pg_require_primed     — additional node: fail if not primed

ha_pg_schema_is_primed() {
    local count

    if ! command -v psql >/dev/null 2>&1; then
        echo "ERROR: psql not found on PATH. Install postgresql-client on this host" >&2
        echo "       so install-ha-node.sh can verify whether mamorisys is already primed." >&2
        return 1
    fi

    if [[ -z "${PG_HOST:-}" || -z "${PG_PORT:-}" || -z "${PG_USER:-}" || -z "${PG_PASSWORD:-}" ]]; then
        echo "ERROR: PG_HOST, PG_PORT, PG_USER, and PG_PASSWORD are required for schema check." >&2
        return 1
    fi

    # Table missing or empty => unprimed. Connection failure is a hard error.
    set +e
    count="$(
        PGPASSWORD="$PG_PASSWORD" psql --host "$PG_HOST" --port "$PG_PORT" -U "$PG_USER" \
            -d mamorisys -Atqc \
            "SELECT COUNT(*) FROM schema_update" 2>/dev/null
    )"
    local rc=$?
    set -e

    if [[ $rc -ne 0 ]]; then
        # Could not query schema_update (missing relation or connect failure).
        # Distinguish connect failure by a simple SELECT 1.
        set +e
        PGPASSWORD="$PG_PASSWORD" psql --host "$PG_HOST" --port "$PG_PORT" -U "$PG_USER" \
            -d mamorisys -Atqc "SELECT 1" >/dev/null 2>&1
        local conn_rc=$?
        set -e
        if [[ $conn_rc -ne 0 ]]; then
            echo "ERROR: cannot connect to mamorisys at ${PG_USER}@${PG_HOST}:${PG_PORT}" >&2
            echo "       Check PG_* credentials and that the database exists." >&2
            return 1
        fi
        export HA_PG_SCHEMA_PRIMED=0
        return 0
    fi

    if [[ -n "$count" && "$count" -gt 0 ]]; then
        export HA_PG_SCHEMA_PRIMED=1
    else
        export HA_PG_SCHEMA_PRIMED=0
    fi
    return 0
}

ha_pg_require_unprimed() {
    ha_pg_schema_is_primed || return 1
    if [[ "${HA_PG_SCHEMA_PRIMED}" == "1" ]]; then
        echo "ERROR: mamorisys already has schema_update rows (cluster already primed)." >&2
        echo "       This looks like an additional node. Use extract-cluster-details.sh" >&2
        echo "       and re-run: bash install-ha-node.sh --env-file <cluster-details.env> ..." >&2
        return 1
    fi
    echo "Postgres mamorisys is unprimed (first-node OK)." >&2
    return 0
}

ha_pg_require_primed() {
    ha_pg_schema_is_primed || return 1
    if [[ "${HA_PG_SCHEMA_PRIMED}" != "1" ]]; then
        echo "ERROR: mamorisys is not primed (no schema_update rows)." >&2
        echo "       Run the first app node without --env-file so it can bootstrap the DB." >&2
        return 1
    fi
    echo "Postgres mamorisys is primed (additional-node OK)." >&2
    return 0
}
