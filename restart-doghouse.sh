#!/usr/bin/env bash
set -euo pipefail

# Restart Scoob doghouse container(s)
# Usage:
#   ./restart-doghouse.sh
#   ./restart-doghouse.sh --pull
#   ./restart-doghouse.sh --rebuild
#
# Notes:
# - --pull: git pull the doghouse repo first
# - --rebuild: docker compose up -d --build --force-recreate

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SELF_DIR"

PULL=0
REBUILD=0

for arg in "$@"; do
  case "$arg" in
    --pull) PULL=1 ;;
    --rebuild) REBUILD=1 ;;
    -h|--help)
      sed -n '1,80p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ "$PULL" == "1" ]]; then
  echo "[restart-doghouse] git pull"
  git pull --ff-only
fi

if [[ "$REBUILD" == "1" ]]; then
  echo "[restart-doghouse] docker compose up (rebuild + force recreate)"
  docker compose up -d --build --force-recreate
else
  echo "[restart-doghouse] docker compose restart"
  docker compose restart
fi

echo "[restart-doghouse] done"
