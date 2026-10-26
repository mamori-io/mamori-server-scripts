#!/usr/bin/env bash
# Load the offline image archive and start analyzer (:5002) + anonymizer (:5001).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE="${1:-}"

if [[ -z "$ARCHIVE" ]]; then
  for candidate in \
    "$ROOT/images/mamori-presidio-en-th-20261023.tgz" \
    "$ROOT/mamori-presidio-en-th-20261023.tgz"; do
    if [[ -f "$candidate" ]]; then
      ARCHIVE="$candidate"
      break
    fi
  done
fi

if [[ -z "${ARCHIVE}" || ! -f "$ARCHIVE" ]]; then
  echo "Usage: $0 <mamori-presidio-en-th-*.tgz>" >&2
  echo "Place the archive next to this script or under images/." >&2
  exit 1
fi

echo "Loading $ARCHIVE"
gunzip -c "$ARCHIVE" | docker load

cd "$ROOT"
docker compose up -d
docker compose ps
echo
echo "Analyzer:   http://$(hostname -I 2>/dev/null | awk '{print $1}'):5002/health"
echo "Anonymizer: http://$(hostname -I 2>/dev/null | awk '{print $1}'):5001/health"
echo "Languages:  en, th  (only these two)"
