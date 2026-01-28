#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${CLAWDBOT_STATE_DIR:-$HOME/.moltbot}"
CFG_PATH="${CLAWDBOT_CONFIG_PATH:-$STATE_DIR/moltbot.json}"

read_secret() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  # Trim trailing newlines
  tr -d '\r\n' < "$path"
}

# Load channel secrets (docker secrets are mounted at /run/secrets/*)
if token="$(read_secret /run/secrets/discord_bot_token)"; then
  export DISCORD_BOT_TOKEN="$token"
  echo "[doghouse] Loaded DISCORD_BOT_TOKEN from docker secret"
fi

if hs="$(read_secret /run/secrets/matrix_homeserver)"; then
  export MATRIX_HOMESERVER="$hs"
  echo "[doghouse] Loaded MATRIX_HOMESERVER from docker secret"
fi

if uid="$(read_secret /run/secrets/matrix_user_id)"; then
  export MATRIX_USER_ID="$uid"
  echo "[doghouse] Loaded MATRIX_USER_ID from docker secret"
fi

if pw="$(read_secret /run/secrets/matrix_password)"; then
  export MATRIX_PASSWORD="$pw"
  echo "[doghouse] Loaded MATRIX_PASSWORD from docker secret"
fi

WORKSPACE_DIR="${DOGHOUSE_WORKSPACE:-$HOME/clawd}"

# Ensure state + workspace dirs exist + are writable by scoob
mkdir -p "$STATE_DIR" "$WORKSPACE_DIR"
chown -R scoob:scoob "$STATE_DIR" "$WORKSPACE_DIR" || true

# One-time non-interactive bootstrap (no TUI)
if [[ ! -f "$CFG_PATH" ]]; then
  echo "[doghouse] First run: moltbot setup"
  # Run setup as scoob so it writes files with the correct ownership.
  gosu scoob /usr/local/bin/moltbot setup --workspace "$WORKSPACE_DIR"
fi

# Wire Scoob to the host ooba OpenAI-compatible API by default
# (does NOT add any cloud keys; uses a dummy apiKey string)
if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
  BASE="${OPENAI_BASE_URL%/}"
  # Ensure /v1 suffix
  if [[ "$BASE" != */v1 ]]; then BASE="$BASE/v1"; fi

  echo "[doghouse] Configuring OpenAI provider -> $BASE"
  # Set the whole provider object in one go so schema validation passes.
  gosu scoob /usr/local/bin/moltbot config set models.providers.openai "{api: 'openai-completions', baseUrl: '$BASE', apiKey: 'ooba', models: []}" || true
fi

# Finally run the gateway as scoob
exec gosu scoob "$@"
