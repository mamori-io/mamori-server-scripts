# Shared AIO Postgres major-version helpers for Mamori all-in-one.
# Safe to source. Does not mutate the host beyond docker inspect/exec reads.
#
# Bundle major for the current AIO product line (new installs and upgrades).
MAMORI_AIO_BUNDLE_PG_MAJOR="${MAMORI_AIO_BUNDLE_PG_MAJOR:-18}"

# Inner script used to scan PG_VERSION files on the data volume.
_aio_pg_scan_ondisk_script() {
    cat <<'EOS'
best=""
for f in /var/lib/postgresql/*/main/PG_VERSION; do
    [ -f "$f" ] || continue
    v=$(tr -d "[:space:]" < "$f")
    case "$v" in
        ""|*[!0-9]*) continue ;;
    esac
    if [ -z "$best" ] || [ "$v" -gt "$best" ]; then
        best="$v"
    fi
done
printf "%s" "$best"
EOS
}

# Read the on-disk cluster major from PG_VERSION under the data volume.
# Prefers the highest complete .../<major>/main/PG_VERSION found.
# Works with a stopped mamori container via --volumes-from.
# Prints major (e.g. 14 or 18) or empty if none found. Returns 0 when found.
aio_pg_ondisk_major() {
    local docker="${DOCKER:-sudo docker}"
    local container="${CONTAINER_NAME:-${CONTAINER:-mamori}}"
    local major=""
    local status=""

    if ! $docker inspect "$container" >/dev/null 2>&1; then
        echo "ERROR: container '$container' not found" >&2
        return 1
    fi

    status="$($docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)"
    if [[ "$status" == "running" ]]; then
        major="$($docker exec "$container" bash -c "$(_aio_pg_scan_ondisk_script)" 2>/dev/null || true)"
    else
        major="$($docker run --rm --volumes-from "$container" ubuntu:noble \
            bash -c "$(_aio_pg_scan_ondisk_script)" 2>/dev/null || true)"
    fi

    if [[ -z "$major" ]]; then
        return 1
    fi
    printf '%s\n' "$major"
    return 0
}

# Try running server version via psql inside the container (port 54321).
# Prints major or empty. Returns 0 when found.
aio_pg_running_major() {
    local docker="${DOCKER:-sudo docker}"
    local container="${CONTAINER_NAME:-${CONTAINER:-mamori}}"
    local ver=""

    if ! $docker inspect "$container" >/dev/null 2>&1; then
        return 1
    fi

    ver="$($docker exec "$container" bash -c '
        export PGPASSWORD
        PGPASSWORD=$(awk "{ sub(/\r$/,\"\"); print }" /opt/mamori/var/derby.properties 2>/dev/null \
            | awk -F "=" "/rms.password=(.)/{print \$2}")
        psql -h 127.0.0.1 -p 54321 -U postgres -d postgres -Atqc "SHOW server_version_num" 2>/dev/null \
            || psql -p 54321 -U postgres -d postgres -Atqc "SHOW server_version_num" 2>/dev/null \
            || true
    ' 2>/dev/null || true)"

    if [[ ! "$ver" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    # server_version_num is like 180007 -> major 18; 140025 -> 14
    printf '%s\n' "$((ver / 10000))"
    return 0
}

# Resolve current AIO PG major: on-disk preferred (upgrade gate), else running.
aio_pg_current_major() {
    local major=""
    if major="$(aio_pg_ondisk_major)"; then
        printf '%s\n' "$major"
        return 0
    fi
    aio_pg_running_major
}

# True if path exists in the mamori data/config volumes (running exec or volumes-from).
aio_pg_volume_path_exists() {
    local relpath="$1"
    local docker="${DOCKER:-sudo docker}"
    local container="${CONTAINER_NAME:-${CONTAINER:-mamori}}"
    local status=""

    status="$($docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)"
    if [[ "$status" == "running" ]]; then
        $docker exec "$container" test -e "$relpath" >/dev/null 2>&1
        return $?
    fi
    $docker run --rm --volumes-from "$container" ubuntu:noble test -e "$relpath" >/dev/null 2>&1
}

# Require on-disk AIO PG major to match the bundle. Exit message to stderr on mismatch.
# Returns 0 on match, 1 on mismatch / undetectable.
aio_pg_require_bundle_major() {
    local expected="${1:-$MAMORI_AIO_BUNDLE_PG_MAJOR}"
    local current=""
    local running=""

    if ! current="$(aio_pg_ondisk_major)"; then
        if ! current="$(aio_pg_running_major)"; then
            echo "ERROR: could not determine AIO PostgreSQL major version from container '${CONTAINER_NAME:-${CONTAINER:-mamori}}'" >&2
            echo "       Expected bundle major: $expected" >&2
            echo "       Migrate first: bash upgrade-aio-postgres-to-18.sh" >&2
            return 1
        fi
    fi

    if [[ "$current" != "$expected" ]]; then
        echo "ERROR: AIO PostgreSQL major is $current; this Mamori bundle requires $expected" >&2
        if [[ "$current" == "14" && "$expected" == "18" ]]; then
            echo "       Run: bash upgrade-aio-postgres-to-18.sh" >&2
            echo "       Then re-run this upgrade (do not start the old PG14-only image after migrate)." >&2
        fi
        return 1
    fi

    # If both 14 and 18 data dirs exist, require the migrate completion marker so a
    # failed partial pg_upgrade cannot pass validation.
    if aio_pg_volume_path_exists "/var/lib/postgresql/14/main/PG_VERSION" \
        && aio_pg_volume_path_exists "/var/lib/postgresql/18/main/PG_VERSION"; then
        if ! aio_pg_volume_path_exists "/var/lib/postgresql/18/main/.mamori_pg_upgrade_complete"; then
            echo "ERROR: Postgres 18 data dir exists alongside 14 but migrate marker is missing" >&2
            echo "       Incomplete migrate? Fix or remove /var/lib/postgresql/18/main after backup," >&2
            echo "       then re-run: bash upgrade-aio-postgres-to-18.sh" >&2
            return 1
        fi
    fi

    # Warn if an old image is still serving a lower major while 18 data exists.
    if running="$(aio_pg_running_major 2>/dev/null)"; then
        if [[ "$running" != "$expected" ]]; then
            echo "WARNING: on-disk Postgres is $current but the running server reports $running" >&2
            echo "         Stop the old container before/during Mamori upgrade; do not keep serving $running." >&2
        fi
    fi

    echo "AIO PostgreSQL major $current matches bundle expectation ($expected)"
    return 0
}
