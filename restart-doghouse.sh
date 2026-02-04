#!/usr/bin/env bash
set -euo pipefail

# Restart a doghouse compose service/container.
#
# Usage:
#   ./restart-doghouse.sh                 # restart default service (doghouse)
#   ./restart-doghouse.sh --service scrappy
#   ./restart-doghouse.sh --pull
#   ./restart-doghouse.sh --rebuild
#
# Notes:
# - --service NAME: docker compose service name (not container_name). Default: "doghouse"
# - --pull: git pull the repo first
# - --rebuild: docker compose up -d --build --force-recreate (for the selected service)

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SELF_DIR"

PULL=0
REBUILD=0
SERVICE="doghouse"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull) PULL=1; shift ;;
    --rebuild) REBUILD=1; shift ;;
    --service)
      SERVICE="${2:-}"
      if [[ -z "$SERVICE" ]]; then
        echo "--service requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      sed -n '1,120p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$PULL" == "1" ]]; then
  echo "[restart-doghouse] git pull"
  git pull --ff-only
fi

if [[ "$REBUILD" == "1" ]]; then
  echo "[restart-doghouse] docker compose up (rebuild + force recreate) service=$SERVICE"
  docker compose up -d --build --force-recreate "$SERVICE"
else
  echo "[restart-doghouse] docker compose restart service=$SERVICE"
  docker compose restart "$SERVICE"
fi

echo "[restart-doghouse] done"
