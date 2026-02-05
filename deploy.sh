#!/usr/bin/env bash
set -euo pipefail

# deploy.sh - doghouse deploy/recreate helper
#
# Goal:
# - Read canonical bot name from secrets/bot_canonical_name
# - Validate required secrets exist (yell + stop if missing)
# - Bring up the compose stack with the correct container_name prefix
# - Optionally pull latest repo changes
#
# Usage:
#   ./deploy.sh
#   ./deploy.sh --pull
#   ./deploy.sh --rebuild
#

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
cd "$SELF_DIR"

PULL=0
REBUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull) PULL=1; shift ;;
    --rebuild) REBUILD=1; shift ;;
    -h|--help)
      sed -n '1,160p' "$0"
      exit 0
      ;;
    *)
      echo "[deploy] ERROR: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "[deploy] ERROR: missing dependency: $1" >&2; exit 1; }
}

need docker

if docker compose version >/dev/null 2>&1; then
  :
else
  echo "[deploy] ERROR: docker compose is not available (need Docker Compose v2: 'docker compose')" >&2
  exit 1
fi

# Canonical name
CANONICAL_NAME="${BOT_CANONICAL_NAME:-}"
if [[ -z "$CANONICAL_NAME" ]]; then
  if [[ -f ./secrets/bot_canonical_name ]]; then
    CANONICAL_NAME="$(tr -d '\r\n' < ./secrets/bot_canonical_name)"
  fi
fi

if [[ -z "$CANONICAL_NAME" ]]; then
  echo "[deploy] ERROR: missing canonical name." >&2
  echo "[deploy] Create ./secrets/bot_canonical_name containing a single line like: scoob" >&2
  exit 1
fi

# Required secrets (files)
REQUIRED_SECRETS=(
  "./secrets/bot_canonical_name"
  "./secrets/github.env"
  "./secrets/gh_token"
  "./secrets/discord_bot_token"
  "./secrets/matrix_homeserver"
  "./secrets/matrix_user_id"
  "./secrets/matrix_password"
  "./secrets/gateway_token"
)

missing=0
for f in "${REQUIRED_SECRETS[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "[deploy] ERROR: required secret missing: $f" >&2
    missing=1
  fi
  # also reject empty secrets
  if [[ -f "$f" ]] && [[ ! -s "$f" ]]; then
    echo "[deploy] ERROR: required secret is empty: $f" >&2
    missing=1
  fi
done

if [[ "$missing" == "1" ]]; then
  echo "[deploy] Aborting due to missing/empty required secrets." >&2
  exit 1
fi

if [[ "$PULL" == "1" ]]; then
  echo "[deploy] git pull"
  git pull --ff-only
fi

# Bring stack up. Use --force-recreate to apply container_name changes reliably.
# If --rebuild is requested, also build.
compose_args=(up -d --force-recreate --remove-orphans)
if [[ "$REBUILD" == "1" ]]; then
  compose_args+=(--build)
  # Cache bust to force Docker to pull the latest head when building from a moving git ref.
  export MOLTBOT_CACHE_BUST="$(date +%s)"
fi

echo "[deploy] BOT_CANONICAL_NAME=$CANONICAL_NAME docker compose ${compose_args[*]}"
BOT_CANONICAL_NAME="$CANONICAL_NAME" docker compose "${compose_args[@]}"

echo "[deploy] Containers:"
docker ps --filter "name=^${CANONICAL_NAME}-doghouse$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' || true
docker ps --filter "name=^${CANONICAL_NAME}-doghouse-mongo$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' || true
docker ps --filter "name=^${CANONICAL_NAME}-doghouse-init$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' || true

echo "[deploy] done"
