#!/usr/bin/env bash
set -euo pipefail

# Restart a doghouse container by canonical bot name.
#
# Usage:
#   ./restart-doghouse.sh
#   ./restart-doghouse.sh --pull
#   ./restart-doghouse.sh --rebuild
#
# Canonical name source:
# - reads ./secrets/bot_canonical_name (single line: scoob|scrappy|...)
# - falls back to BOT_CANONICAL_NAME env var
# - falls back to "scoob"
#
# This targets the Docker container name:
#   <canonical>-doghouse
#
# Notes:
# - --pull: git pull the repo first
# - --rebuild: docker compose up -d --build --force-recreate (service: doghouse)

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SELF_DIR"

PULL=0
REBUILD=0

# Determine canonical name
CANONICAL_NAME="${BOT_CANONICAL_NAME:-}"
if [[ -z "$CANONICAL_NAME" ]] && [[ -f ./secrets/bot_canonical_name ]]; then
  CANONICAL_NAME="$(tr -d '\r\n' < ./secrets/bot_canonical_name)"
fi
CANONICAL_NAME="${CANONICAL_NAME:-scoob}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull) PULL=1; shift ;;
    --rebuild) REBUILD=1; shift ;;
    -h|--help)
      sed -n '1,140p' "$0"
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

CONTAINER_NAME="${CANONICAL_NAME}-doghouse"

if [[ "$REBUILD" == "1" ]]; then
  echo "[restart-doghouse] docker compose up (rebuild + force recreate) BOT_CANONICAL_NAME=$CANONICAL_NAME"
  BOT_CANONICAL_NAME="$CANONICAL_NAME" docker compose up -d --build --force-recreate doghouse
else
  echo "[restart-doghouse] docker restart $CONTAINER_NAME"
  docker restart "$CONTAINER_NAME"
fi

echo "[restart-doghouse] done"
