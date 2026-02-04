#!/usr/bin/env bash
set -euo pipefail

# migrate-volumes.sh
#
# Rescue data from the *old* compose-prefixed volumes and migrate into the new
# explicit (canonical-name) volumes defined in docker-compose.yml.
#
# This script is HOST-side. It does NOT delete anything by default.
# If you pass --delete-old it will remove the old volumes after copying.
#
# Usage:
#   ./migrate-volumes.sh
#   ./migrate-volumes.sh --delete-old

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SELF_DIR"

DELETE_OLD=0
if [[ "${1:-}" == "--delete-old" ]]; then
  DELETE_OLD=1
fi

# Canonical name
CANONICAL_NAME="${BOT_CANONICAL_NAME:-}"
if [[ -z "$CANONICAL_NAME" ]] && [[ -f ./secrets/bot_canonical_name ]]; then
  CANONICAL_NAME="$(tr -d '\r\n' < ./secrets/bot_canonical_name)"
fi
CANONICAL_NAME="${CANONICAL_NAME:-scoob}"

old_workspace_vol="doghouse_doghouse_workspace"
old_openclaw_ws_vol="doghouse_doghouse_openclaw_workspace"
old_state_vol="doghouse_doghouse_state"

new_legacy_vol="${CANONICAL_NAME}_doghouse_workspace_legacy"
new_home_vol="${CANONICAL_NAME}_doghouse_home"
new_state_vol="${CANONICAL_NAME}_doghouse_state"

say() { echo "[migrate] $*"; }

# Ensure old volumes exist
for v in "$old_workspace_vol" "$old_openclaw_ws_vol" "$old_state_vol"; do
  if ! docker volume inspect "$v" >/dev/null 2>&1; then
    say "ERROR: expected old volume not found: $v"
    exit 1
  fi
done

# Create new volumes if absent
for v in "$new_legacy_vol" "$new_home_vol" "$new_state_vol"; do
  if docker volume inspect "$v" >/dev/null 2>&1; then
    :
  else
    say "Creating volume: $v"
    docker volume create "$v" >/dev/null
  fi
done

# Copy legacy workspace volume -> new legacy volume (full copy)
say "Copying legacy workspace: $old_workspace_vol -> $new_legacy_vol"
docker run --rm \
  -v "$old_workspace_vol":/from:ro \
  -v "$new_legacy_vol":/to \
  alpine:3.19 sh -lc 'set -e; cp -a /from/. /to/'

# Also copy legacy workspace into the new HOME/workspace volume.
# This makes /home/scoob start with the rescued files.
say "Copying legacy workspace into home: $old_workspace_vol -> $new_home_vol"
docker run --rm \
  -v "$old_workspace_vol":/from:ro \
  -v "$new_home_vol":/to \
  alpine:3.19 sh -lc 'set -e; cp -a /from/. /to/'

# Preserve anything that was in the old openclaw workspace volume by copying it into HOME too (best-effort).
say "Copying old openclaw workspace into home (if any): $old_openclaw_ws_vol -> $new_home_vol"
docker run --rm \
  -v "$old_openclaw_ws_vol":/from:ro \
  -v "$new_home_vol":/to \
  alpine:3.19 sh -lc 'set -e; cp -a /from/. /to/ || true'

# Copy state volume -> new state volume (full copy)
say "Copying state: $old_state_vol -> $new_state_vol"
docker run --rm \
  -v "$old_state_vol":/from:ro \
  -v "$new_state_vol":/to \
  alpine:3.19 sh -lc 'set -e; cp -a /from/. /to/'

say "Done copying. New volumes:" 
docker volume ls | grep -E "^local\s+${CANONICAL_NAME}_doghouse_(state|home|workspace_legacy)" || true

say "Next: run ./deploy.sh --rebuild to recreate containers with new named volumes."

if [[ "$DELETE_OLD" == "1" ]]; then
  say "Deleting OLD volumes (requested):"
  say " - $old_workspace_vol"
  say " - $old_openclaw_ws_vol"
  docker volume rm "$old_workspace_vol" "$old_openclaw_ws_vol" >/dev/null
  say "(kept old state volume: $old_state_vol)"
fi
