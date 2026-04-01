#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Uninstall Mamori all-in-one Docker deployment (containers, images, and optionally volumes).
# This script is standalone and does not run or reference update-nginx-from-image.sh.
#
# Usage:
#   ./uninstall.sh              Prompt for confirmation, then remove containers, images, and volumes.
#   ./uninstall.sh --yes        Same without typing "yes" (automation only).
#   ./uninstall.sh --keep-volumes   Remove containers and images but keep all mamori-* Docker volumes (data preserved).
#
set -u

DOCKER="${DOCKER:-sudo docker}"

usage() {
  echo "Usage: $0 [--keep-volumes] [--yes]" >&2
  echo "  --keep-volumes   Remove containers/images but not Docker volumes" >&2
  echo "  --yes            Skip confirmation prompt" >&2
  exit "${1:-0}"
}

KEEP_VOLUMES=0
YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-volumes) KEEP_VOLUMES=1 ;;
    --yes) YES=1 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

VOLUMES=(
  mamori-var
  mamori-nginx-conf
  mamori-data
  mamori-pg-conf
  mamori-influxdb
  mamori-influxdb-data
  mamori-influxdb-conf
  mamori-grafana
)

echo "Stopping containers (if present)..."
$DOCKER stop mamori 2>/dev/null || true
$DOCKER stop mamori-wireguard 2>/dev/null || true

echo "Removing old upgrade containers (mamori-<timestamp>) if present..."
while IFS= read -r name; do
  if [[ -n "$name" ]] && [[ "$name" =~ ^mamori-[0-9]+$ ]]; then
    echo "  Removing container: $name"
    $DOCKER rm -f "$name" 2>/dev/null || true
  fi
done < <($DOCKER ps -a --format '{{.Names}}' 2>/dev/null || true)

echo "Removing main containers..."
$DOCKER rm -f mamori mamori-wireguard 2>/dev/null || true

echo "Removing images (if present)..."
$DOCKER rmi iomamori/mamori-all-in-one:latest 2>/dev/null || true
$DOCKER rmi iomamori/mamori-all-in-one 2>/dev/null || true
$DOCKER rmi mamori-wireguard mamori-alpine-boringtun 2>/dev/null || true

if [[ "$KEEP_VOLUMES" -eq 1 ]]; then
  echo "Done (--keep-volumes: Docker volumes were not removed)."
  exit 0
fi

if [[ "$YES" -ne 1 ]]; then
  echo ""
  echo "The following Docker volumes will be PERMANENTLY DELETED:"
  for v in "${VOLUMES[@]}"; do
    echo "  - $v"
  done
  echo ""
  read -r -p "Type 'yes' to delete these volumes: " ans
  if [[ "$ans" != "yes" ]]; then
    echo "Aborted. Containers/images may already be removed; volumes were kept."
    exit 1
  fi
fi

echo "Removing Docker volumes..."
for v in "${VOLUMES[@]}"; do
  if $DOCKER volume rm "$v" 2>/dev/null; then
    echo "  Removed: $v"
  else
    echo "  Skipped or missing: $v"
  fi
done

echo "Uninstall complete."
