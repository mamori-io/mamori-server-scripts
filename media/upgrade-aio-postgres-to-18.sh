#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Migrate an existing Mamori all-in-one Postgres data volume from 14 to 18
# BEFORE upgrading the Mamori container to a PG18-only bundle image.
#
# This does not replace the Mamori app image. After a successful migrate,
# run media/upgrade-dockerhub.sh or media/upgrade-file.sh (with --validate).
# Do not restart the old PG14-only Mamori image against the migrated volumes.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/aio-pg-version.sh"

DOCKER="${DOCKER:-sudo docker}"
CONTAINER_NAME="${CONTAINER_NAME:-mamori}"
OLD_VERSION=14
PG_VERSION=18
HELPER_IMAGE="${HELPER_IMAGE:-mamori-aio-pg-upgrade:14-18}"
HELPER_DIR="$SCRIPT_DIR/aio-pg-upgrade-helper"
PG18_CONF_TGZ="${PG18_CONF_TGZ:-$SCRIPT_DIR/config/pg18_conf.tgz}"

MODE="migrate"
SKIP_BACKUP=0
CONFIRM_SKIP_BACKUP=0
DRY_RUN=0
NO_STOP=0

usage() {
    cat <<'EOF'
Usage: upgrade-aio-postgres-to-18.sh [options]

Migrate AIO Postgres volumes from 14 to 18 using a dual-binary helper image.
Run this before upgrading Mamori to a PG18-only bundle.

Options:
  --dry-run              Run pg_upgrade --check only (no lasting migrate)
  --skip-backup          Skip backup-aio.sh (requires --i-know-what-im-doing)
  --i-know-what-im-doing Confirm --skip-backup
  --prune-old            After soak on PG18: remove leftover 14 data/config
  --no-stop              Do not stop the mamori container (not recommended)
  -h, --help             Show this help

Environment:
  DOCKER           Docker CLI (default: sudo docker)
  CONTAINER_NAME   Mamori container (default: mamori)
  HELPER_IMAGE     Dual-binary helper tag (default: mamori-aio-pg-upgrade:14-18)
  PG18_CONF_TGZ    Path to pg18_conf.tgz (default: media/config/pg18_conf.tgz)

Typical flow:
  bash upgrade-aio-postgres-to-18.sh
  bash upgrade-dockerhub.sh --validate
  bash upgrade-dockerhub.sh
  # after soak:
  bash upgrade-aio-postgres-to-18.sh --prune-old
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --skip-backup)
            SKIP_BACKUP=1
            shift
            ;;
        --i-know-what-im-doing)
            CONFIRM_SKIP_BACKUP=1
            shift
            ;;
        --prune-old)
            MODE="prune"
            shift
            ;;
        --no-stop)
            NO_STOP=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$SKIP_BACKUP" -eq 1 && "$CONFIRM_SKIP_BACKUP" -ne 1 && "$MODE" == "migrate" ]]; then
    echo "ERROR: --skip-backup requires --i-know-what-im-doing" >&2
    exit 1
fi

if ! $DOCKER inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "ERROR: container '$CONTAINER_NAME' not found" >&2
    exit 1
fi

# Confirm expected named volumes are attached (best-effort via mounts).
mounts="$($DOCKER inspect -f '{{range .Mounts}}{{.Name}} {{.Destination}}{{"\n"}}{{end}}' "$CONTAINER_NAME")"
echo "$mounts" | grep -q '/var/lib/postgresql' || {
    echo "ERROR: container does not mount a Postgres data volume at /var/lib/postgresql" >&2
    exit 1
}
echo "$mounts" | grep -q '/etc/postgresql' || {
    echo "ERROR: container does not mount a Postgres config volume at /etc/postgresql" >&2
    exit 1
}
echo "$mounts" | grep -q '/opt/mamori/var' || {
    echo "ERROR: container does not mount mamori-var at /opt/mamori/var" >&2
    exit 1
}

ensure_helper_image() {
    if $DOCKER image inspect "$HELPER_IMAGE" >/dev/null 2>&1; then
        echo "Using helper image: $HELPER_IMAGE"
        return 0
    fi
    echo "Building helper image $HELPER_IMAGE (first run; installs postgresql-14 and postgresql-18)..."
    $DOCKER build -t "$HELPER_IMAGE" "$HELPER_DIR"
}

run_helper() {
    local check_only="$1"
    local prune_old="$2"
    local args=()

    [[ -f "$PG18_CONF_TGZ" ]] || {
        echo "ERROR: pg18 conf tarball not found: $PG18_CONF_TGZ" >&2
        exit 1
    }

    ensure_helper_image

    # Bind the named volumes by reusing the mamori container's mounts via --volumes-from.
    $DOCKER run --rm \
        --volumes-from "$CONTAINER_NAME" \
        -v "$PG18_CONF_TGZ:/media/pg18_conf.tgz:ro" \
        -e "OLD_VERSION=$OLD_VERSION" \
        -e "PG_VERSION=$PG_VERSION" \
        -e "CHECK_ONLY=$check_only" \
        -e "PRUNE_OLD=$prune_old" \
        "$HELPER_IMAGE"
}

stop_mamori_if_needed() {
    if [[ "$NO_STOP" -eq 1 ]]; then
        echo "WARNING: --no-stop set; Postgres must not be running during migrate/prune" >&2
        return 0
    fi
    local status
    status="$($DOCKER inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    if [[ "$status" == "running" ]]; then
        echo "Stopping container $CONTAINER_NAME for Postgres migrate window..."
        $DOCKER stop "$CONTAINER_NAME"
    else
        echo "Container $CONTAINER_NAME is not running ($status)"
    fi
}

if [[ "$MODE" == "prune" ]]; then
    echo "=== Prune old AIO Postgres ${OLD_VERSION} data ==="
    # Prefer verifying live/on-disk major is already 18.
    if current="$(aio_pg_current_major 2>/dev/null)"; then
        if [[ "$current" != "$PG_VERSION" ]]; then
            echo "ERROR: current AIO Postgres major is $current; refuse to prune ${OLD_VERSION}" >&2
            exit 1
        fi
    fi
    stop_mamori_if_needed
    run_helper 0 1
    echo "Prune finished. You may start Mamori again if it was stopped."
    if [[ "$NO_STOP" -ne 1 ]]; then
        $DOCKER start "$CONTAINER_NAME" || true
    fi
    exit 0
fi

echo "=== Mamori AIO Postgres ${OLD_VERSION} -> ${PG_VERSION} ==="

# Idempotent success if already on 18.
if current="$(aio_pg_current_major 2>/dev/null)"; then
    if [[ "$current" == "$PG_VERSION" ]]; then
        echo "Already on PostgreSQL $PG_VERSION. Nothing to migrate."
        exit 0
    fi
    if [[ "$current" != "$OLD_VERSION" ]]; then
        echo "ERROR: unexpected AIO Postgres major $current (expected $OLD_VERSION or $PG_VERSION)" >&2
        exit 1
    fi
    echo "Detected AIO Postgres major $current"
fi

if [[ "$SKIP_BACKUP" -eq 0 ]]; then
    echo "Running backup-aio.sh..."
    bash "$SCRIPT_DIR/backup-aio.sh"
else
    echo "WARNING: skipping backup (--skip-backup)"
fi

stop_mamori_if_needed

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry-run: pg_upgrade --check only"
    run_helper 1 0
    echo "Dry-run check succeeded. Restarting container (still on ${OLD_VERSION})..."
    if [[ "$NO_STOP" -ne 1 ]]; then
        $DOCKER start "$CONTAINER_NAME"
    fi
    exit 0
fi

run_helper 0 0

echo ""
echo "Postgres data migrated to ${PG_VERSION}."
echo "Container $CONTAINER_NAME was left STOPPED."
echo "Do NOT start the old PG${OLD_VERSION}-only Mamori image against these volumes."
echo "Next steps:"
echo "  bash upgrade-dockerhub.sh --validate   # or upgrade-file.sh --validate"
echo "  bash upgrade-dockerhub.sh              # recreate on PG${PG_VERSION}-only image"
echo "After soak:"
echo "  bash upgrade-aio-postgres-to-18.sh --prune-old"
