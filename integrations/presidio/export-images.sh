#!/usr/bin/env bash
# Export the running Presidio images to a gzip docker-save archive.
set -euo pipefail

OUT="${1:-mamori-presidio-en-th-$(date +%Y%m%d).tgz}"
ANALYZER_IMAGE="${ANALYZER_IMAGE:-mamori/presidio-analyzer:thai}"
ANONYMIZER_IMAGE="${ANONYMIZER_IMAGE:-ghcr.io/data-privacy-stack/presidio-anonymizer:latest}"

echo "Saving $ANALYZER_IMAGE and $ANONYMIZER_IMAGE -> $OUT"
docker save "$ANALYZER_IMAGE" "$ANONYMIZER_IMAGE" | gzip -1 > "${OUT}.tmp"
mv "${OUT}.tmp" "$OUT"
ls -lh "$OUT"
md5sum "$OUT"
