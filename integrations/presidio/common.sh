#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Shared defaults for Presidio host install / upgrade / uninstall.
# Image build lives in docker-db-scripts/presidio.
#

DOCKER="${DOCKER:-docker}"

ANALYZER_NAME="${ANALYZER_NAME:-presidio-analyzer}"
ANONYMIZER_NAME="${ANONYMIZER_NAME:-presidio-anonymizer}"
ANALYZER_IMAGE="${ANALYZER_IMAGE:-mamori/presidio-analyzer:thai}"
ANONYMIZER_IMAGE="${ANONYMIZER_IMAGE:-ghcr.io/data-privacy-stack/presidio-anonymizer:latest}"
ANALYZER_PORT="${ANALYZER_PORT:-5002}"
ANONYMIZER_PORT="${ANONYMIZER_PORT:-5001}"

ARCHIVE_NAME="${ARCHIVE_NAME:-mamori-presidio-en-th-20261023.tgz}"
ARCHIVE_URL="${ARCHIVE_URL:-https://mamori-io.sgp1.digitaloceanspaces.com/docker-images/${ARCHIVE_NAME}}"

PRESIDIO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${CACHE_DIR:-$PRESIDIO_ROOT/images}"

container_exists() {
    $DOCKER inspect "$1" >/dev/null 2>&1
}

container_running() {
    [[ "$($DOCKER inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

image_present() {
    [[ -n "$($DOCKER images -q "$1" 2>/dev/null || true)" ]]
}

host_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}

ensure_archive() {
    local archive="${1:-}"
    if [[ -n "$archive" ]]; then
        if [[ ! -f "$archive" ]]; then
            echo "Archive not found: $archive" >&2
            return 1
        fi
        echo "$archive"
        return 0
    fi
    for candidate in \
        "$CACHE_DIR/$ARCHIVE_NAME" \
        "$PRESIDIO_ROOT/$ARCHIVE_NAME"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    mkdir -p "$CACHE_DIR"
    local dest="$CACHE_DIR/$ARCHIVE_NAME"
    echo "Downloading $ARCHIVE_URL" >&2
    curl -fL --retry 3 -o "$dest.tmp" "$ARCHIVE_URL"
    mv "$dest.tmp" "$dest"
    echo "$dest"
}

load_archive() {
    local archive="$1"
    echo "Loading $archive"
    gunzip -c "$archive" | $DOCKER load
}

create_analyzer() {
    $DOCKER create \
        --name "$ANALYZER_NAME" \
        --restart unless-stopped \
        --log-opt max-size=10m --log-opt max-file=10 \
        -p "${ANALYZER_PORT}:3000" \
        --health-cmd "curl -f http://localhost:3000/health || exit 1" \
        --health-interval 30s \
        --health-timeout 3s \
        --health-retries 3 \
        --health-start-period 30s \
        "$ANALYZER_IMAGE"
}

create_anonymizer() {
    $DOCKER create \
        --name "$ANONYMIZER_NAME" \
        --restart unless-stopped \
        --log-opt max-size=10m --log-opt max-file=10 \
        -p "${ANONYMIZER_PORT}:3000" \
        --health-cmd "curl -f http://localhost:3000/health || exit 1" \
        --health-interval 30s \
        --health-timeout 3s \
        --health-retries 3 \
        --health-start-period 30s \
        "$ANONYMIZER_IMAGE"
}

print_status() {
    $DOCKER ps -a --filter "name=^${ANALYZER_NAME}$" --filter "name=^${ANONYMIZER_NAME}$" \
        --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    local ip
    ip="$(host_ip)"
    echo
    echo "Analyzer:   http://${ip:-127.0.0.1}:${ANALYZER_PORT}/health"
    echo "Anonymizer: http://${ip:-127.0.0.1}:${ANONYMIZER_PORT}/health"
    echo "Languages:  en, th  (only these two)"
}
