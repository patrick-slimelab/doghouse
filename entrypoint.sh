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

if gt="$(read_secret /run/secrets/gateway_token)"; then
  export CLAWDBOT_GATEWAY_TOKEN="$gt"
  echo "[doghouse] Loaded CLAWDBOT_GATEWAY_TOKEN from docker secret"
fi

WORKSPACE_DIR="${DOGHOUSE_WORKSPACE:-$HOME/clawd}"

# Ensure state + workspace dirs exist + are writable by scoob
mkdir -p "$STATE_DIR" "$WORKSPACE_DIR"

# If the volume contains old root-owned/other-uid files, try to fix ownership.
# Some Docker setups can emit noisy EPERM/EACCES for unreadable entries; that's OK.
chown -R scoob:scoob "$STATE_DIR" "$WORKSPACE_DIR" 2>/dev/null || true

# One-time non-interactive bootstrap (no TUI)
if [[ ! -f "$CFG_PATH" ]]; then
  echo "[doghouse] First run: moltbot setup"
  gosu scoob /usr/local/bin/moltbot setup --workspace "$WORKSPACE_DIR"
fi

# Enforce workspace every boot (fixes legacy configs pointing to /home/node/clawd)
echo "[doghouse] Enforcing agents.defaults.workspace=$WORKSPACE_DIR"
gosu scoob /usr/local/bin/moltbot config set agents.defaults.workspace "$WORKSPACE_DIR" || true

# Open DMs (disable pairing) for Scoob on Discord + Matrix
# This makes the bot reachable to anyone via DM.
echo "[doghouse] Configuring Discord DMs: open"
gosu scoob /usr/local/bin/moltbot config set channels.discord.enabled true || true
gosu scoob /usr/local/bin/moltbot config set channels.discord.dm.policy "open" || true
gosu scoob /usr/local/bin/moltbot config set channels.discord.dm.allowFrom "['*']" || true

echo "[doghouse] Configuring Matrix DMs: open"
gosu scoob /usr/local/bin/moltbot config set channels.matrix.enabled true || true
gosu scoob /usr/local/bin/moltbot config set channels.matrix.dm.policy "open" || true
gosu scoob /usr/local/bin/moltbot config set channels.matrix.dm.allowFrom "['*']" || true

# Ensure gateway is allowed to run (required even after setup if mode is still unset)
MODE="$(gosu scoob /usr/local/bin/moltbot config get gateway.mode 2>/dev/null || true)"
if [[ -z "${MODE// }" || "$MODE" == "null" ]]; then
  echo "[doghouse] Setting gateway.mode=local"
  gosu scoob /usr/local/bin/moltbot config set gateway.mode local || true
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
