#!/bin/bash
# Runs inside the mamori-aio-pg-upgrade helper image.
# Expects volumes:
#   /var/lib/postgresql  (mamori-data)
#   /etc/postgresql      (mamori-pg-conf)
#   /opt/mamori/var       (mamori-var; derby.properties for initdb password)
#   /media/pg18_conf.tgz (optional; AIO PG 18 conf tarball)
set -euo pipefail

OLD_VERSION="${OLD_VERSION:-14}"
PG_VERSION="${PG_VERSION:-18}"
CHECK_ONLY="${CHECK_ONLY:-0}"
PRUNE_OLD="${PRUNE_OLD:-0}"

PGDATAOLD="/var/lib/postgresql/${OLD_VERSION}/main"
PGDATANEW="/var/lib/postgresql/${PG_VERSION}/main"
PGCONFOLD="/etc/postgresql/${OLD_VERSION}/main"
PGCONFNEW="/etc/postgresql/${PG_VERSION}/main"
PGBINOLD="/usr/lib/postgresql/${OLD_VERSION}/bin"
PGBINNEW="/usr/lib/postgresql/${PG_VERSION}/bin"
DONE_MARKER="${PGDATANEW}/.mamori_pg_upgrade_complete"

echo "=== Mamori AIO Postgres migrate (${OLD_VERSION} -> ${PG_VERSION}) ==="

if [[ "$PRUNE_OLD" == "1" ]]; then
    if [[ ! -f "$DONE_MARKER" && ! -f "${PGDATANEW}/PG_VERSION" ]]; then
        echo "ERROR: cannot prune ${OLD_VERSION}; ${PG_VERSION} data dir missing" >&2
        exit 1
    fi
    if [[ -f "${PGDATANEW}/PG_VERSION" ]]; then
        new_major="$(tr -d '[:space:]' < "${PGDATANEW}/PG_VERSION")"
        if [[ "$new_major" != "$PG_VERSION" ]]; then
            echo "ERROR: ${PGDATANEW}/PG_VERSION is '${new_major}', expected ${PG_VERSION}" >&2
            exit 1
        fi
    fi
    echo "Removing old Postgres ${OLD_VERSION} data and config..."
    rm -rf "/var/lib/postgresql/${OLD_VERSION}" "/etc/postgresql/${OLD_VERSION}"
    echo "Prune complete."
    exit 0
fi

if [[ -f "$DONE_MARKER" ]]; then
    echo "Postgres ${PG_VERSION} migrate already complete (${DONE_MARKER}). Nothing to migrate."
    exit 0
fi

if [[ -d "$PGDATANEW" ]]; then
    echo "ERROR: incomplete Postgres ${PG_VERSION} data directory at ${PGDATANEW}" >&2
    echo "       Remove it (and retry) only after confirming you have a backup:" >&2
    echo "       rm -rf ${PGDATANEW}" >&2
    exit 1
fi

if [[ ! -d "$PGDATAOLD" || ! -f "${PGDATAOLD}/PG_VERSION" ]]; then
    echo "ERROR: old data directory missing: ${PGDATAOLD}" >&2
    exit 1
fi

old_major="$(tr -d '[:space:]' < "${PGDATAOLD}/PG_VERSION")"
if [[ "$old_major" != "$OLD_VERSION" ]]; then
    echo "ERROR: ${PGDATAOLD}/PG_VERSION is '${old_major}', expected ${OLD_VERSION}" >&2
    exit 1
fi

if [[ ! -x "${PGBINOLD}/postgres" || ! -x "${PGBINNEW}/postgres" ]]; then
    echo "ERROR: both PostgreSQL ${OLD_VERSION} and ${PG_VERSION} binaries are required in this helper" >&2
    exit 1
fi

if [[ ! -f "${PGCONFOLD}/postgresql.conf" ]]; then
    echo "ERROR: old config missing: ${PGCONFOLD}/postgresql.conf" >&2
    exit 1
fi

# Ensure no postmaster is running against either cluster.
for bin in "$PGBINOLD" "$PGBINNEW"; do
    if [[ -x "${bin}/pg_ctl" ]]; then
        "${bin}/pg_ctl" status -D "$PGDATAOLD" >/dev/null 2>&1 && {
            echo "ERROR: old cluster appears to be running; stop Mamori/Postgres first" >&2
            exit 1
        } || true
        "${bin}/pg_ctl" status -D "$PGDATANEW" >/dev/null 2>&1 && {
            echo "ERROR: new cluster appears to be running; stop it first" >&2
            exit 1
        } || true
    fi
done

mkdir -p "$PGCONFNEW"
cd "$PGCONFNEW"
if [[ ! -f postgresql.conf ]]; then
    if [[ -f /media/pg18_conf.tgz ]]; then
        echo "Unpacking /media/pg18_conf.tgz into ${PGCONFNEW}"
        tar zxvf /media/pg18_conf.tgz
    else
        echo "ERROR: /media/pg18_conf.tgz not mounted; cannot seed ${PG_VERSION} config" >&2
        exit 1
    fi
fi

PGPASSWORD="$(awk '{ sub(/\r$/,""); print }' /opt/mamori/var/derby.properties \
    | awk -F '=' '/rms.password=(.)/{print $2}')"
if [[ -z "$PGPASSWORD" ]]; then
    echo "ERROR: could not read rms.password from /opt/mamori/var/derby.properties" >&2
    exit 1
fi

chown -R postgres:postgres /var/lib/postgresql /etc/postgresql

echo "$PGPASSWORD" > /tmp/pgpassword.txt
chown postgres:postgres /tmp/pgpassword.txt
chmod 600 /tmp/pgpassword.txt

echo "Initializing new Postgres ${PG_VERSION} cluster..."
runuser -u postgres -- "${PGBINNEW}/initdb" \
    -D "$PGDATANEW" -A md5 --pwfile=/tmp/pgpassword.txt
rm -f /tmp/pgpassword.txt

cd "$PGDATANEW"
export PGBINOLD PGBINNEW PGDATAOLD PGDATANEW

CHECK_ARGS=(
    --old-options "-c config_file=${PGCONFOLD}/postgresql.conf"
    --new-options "-c config_file=${PGCONFNEW}/postgresql.conf"
)

echo "Running pg_upgrade --check..."
runuser -u postgres -- "${PGBINNEW}/pg_upgrade" --check "${CHECK_ARGS[@]}"

if [[ "$CHECK_ONLY" == "1" ]]; then
    echo "Check-only mode: pg_upgrade --check succeeded. Not migrating."
    echo "Cleaning incomplete new cluster created for --check..."
    rm -rf "$PGDATANEW"
    # Keep new conf so a real migrate can reuse it; harmless if left.
    exit 0
fi

echo "Running pg_upgrade..."
runuser -u postgres -- "${PGBINNEW}/pg_upgrade" "${CHECK_ARGS[@]}"

# Marker so a failed partial initdb/pg_upgrade is not treated as success next run.
runuser -u postgres -- touch "$DONE_MARKER"

echo "Upgrade finished."
echo "Postgres ${PG_VERSION} data is ready under ${PGDATANEW}."
echo "Do NOT start the old PG${OLD_VERSION}-only Mamori image against this volume."
echo "Next: run the Mamori AIO upgrade to a PG${PG_VERSION} bundle image."
