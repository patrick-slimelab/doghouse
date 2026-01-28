#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${CLAWDBOT_STATE_DIR:-$HOME/.moltbot}"
CFG_PATH="${CLAWDBOT_CONFIG_PATH:-$STATE_DIR/moltbot.json}"

# Ensure state dir exists + is writable by node
mkdir -p "$STATE_DIR"
chown -R node:node "$STATE_DIR" || true

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

  echo "[doghouse] Configuring OpenAI baseUrl -> $BASE"
    gosu node /usr/local/bin/moltbot config set models.providers.openai.baseUrl "$BASE" || true
  gosu node /usr/local/bin/moltbot config set models.providers.openai.apiKey "ooba" || true
fi

# Finally run the gateway as node
exec gosu node "$@"
