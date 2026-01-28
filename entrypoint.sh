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

# Ensure state + workspace dirs exist + are writable by node
mkdir -p "$STATE_DIR" "$HOME/clawd"
chown -R node:node "$STATE_DIR" "$HOME/clawd" || true

# One-time non-interactive bootstrap (no TUI)
if [[ ! -f "$CFG_PATH" ]]; then
  echo "[doghouse] First run: moltbot setup"
  # Run setup as node so it writes files with the correct ownership.
  gosu node /usr/local/bin/moltbot setup --workspace "$HOME/clawd"
fi

# Wire Scoob to the host ooba OpenAI-compatible API by default
# (does NOT add any cloud keys; uses a dummy apiKey string)
if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
  BASE="${OPENAI_BASE_URL%/}"
  # Ensure /v1 suffix
  if [[ "$BASE" != */v1 ]]; then BASE="$BASE/v1"; fi

  echo "[doghouse] Configuring OpenAI provider -> $BASE"
  # Set the whole provider object in one go so schema validation passes.
  gosu node /usr/local/bin/moltbot config set models.providers.openai "{api: 'openai-completions', baseUrl: '$BASE', apiKey: 'ooba', models: []}" || true
fi

# Finally run the gateway as node
exec gosu node "$@"
