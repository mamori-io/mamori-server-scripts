#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# After a verified upgrade, remove leftover backup Mamori containers and images
# (mamori-<timestamp> containers, mamori-old / mamori-<timestamp> images).
#
# Always run this after you have verified the upgrade. If leftovers remain and
# the host reboots, multiple Mamori containers with --restart always can start.
#
# Usage:
#   bash cleanup.sh
#   DOCKER=docker bash cleanup.sh
#
set -euo pipefail

DOCKER="${DOCKER:-sudo docker}"

usage() {
    cat <<'EOF'
Usage: cleanup.sh

Removes backup Mamori containers (name mamori-<digits>) and leftover upgrade
images (mamori-old, mamori-<digits>). Does not remove the running "mamori"
container, current iomamori/mamori-all-in-one (or mamori-all-in-one) image,
or any Docker volumes.

EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

echo "Mamori upgrade cleanup"
echo "  DOCKER=$DOCKER"
echo ""

# Backup containers left by upgrade rename: mamori-<unix-timestamp>
FOUND_CONTAINERS=()
while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ "$name" =~ ^mamori-[0-9]+$ ]]; then
        FOUND_CONTAINERS+=("$name")
    fi
done < <($DOCKER ps -a --format '{{.Names}}' 2>/dev/null || true)

if [[ ${#FOUND_CONTAINERS[@]} -eq 0 ]]; then
    echo "No old mamori containers found"
else
    echo "Found old Mamori containers: ${FOUND_CONTAINERS[*]}"
    $DOCKER rm -f "${FOUND_CONTAINERS[@]}"
fi

# Leftover tagged images from upgrade (mamori-old) or historic mamori-<digits> tags
FOUND_IMAGES=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # repo:tag id — keep id (last field) unique
    img_id="${line##* }"
    ref="${line% *}"
    case "$ref" in
        mamori-old|mamori-old:*|mamori-[0-9]*|mamori-[0-9]*:*)
            FOUND_IMAGES+=("$img_id")
            ;;
    esac
done < <($DOCKER images --format '{{.Repository}}:{{.Tag}} {{.ID}}' 2>/dev/null || true)

# Also catch filter-based matches (repository name patterns)
while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    FOUND_IMAGES+=("$id")
done < <($DOCKER images -f 'reference=mamori-[0-9]*' -q 2>/dev/null || true)
while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    FOUND_IMAGES+=("$id")
done < <($DOCKER images -f 'reference=mamori-old' -q 2>/dev/null || true)
while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    FOUND_IMAGES+=("$id")
done < <($DOCKER images -f 'reference=mamori-old:*' -q 2>/dev/null || true)

# Unique image IDs
UNIQUE_IMAGES=()
if [[ ${#FOUND_IMAGES[@]} -gt 0 ]]; then
    while IFS= read -r id; do
        [[ -n "$id" ]] && UNIQUE_IMAGES+=("$id")
    done < <(printf '%s\n' "${FOUND_IMAGES[@]}" | awk 'NF && !seen[$0]++')
fi

if [[ ${#UNIQUE_IMAGES[@]} -eq 0 ]]; then
    echo "No old mamori images found"
else
    echo "Found old Mamori images: ${UNIQUE_IMAGES[*]}"
    $DOCKER image rm -f "${UNIQUE_IMAGES[@]}"
fi

echo ""
echo "Cleanup complete."
