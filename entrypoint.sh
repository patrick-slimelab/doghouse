#!/usr/bin/env bash
set -euo pipefail

# Ensure state dir exists
mkdir -p "$HOME/.clawdbot"

# One-time non-interactive bootstrap (no TUI)
if [[ ! -f "$HOME/.clawdbot/moltbot.json" ]]; then
  echo "[doghouse] First run: moltbot setup"
  /usr/local/bin/moltbot setup --workspace "$HOME/clawd"
fi

# Wire Scoob to the host ooba OpenAI-compatible API by default
# (does NOT add any cloud keys; uses a dummy apiKey string)
if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
  BASE="${OPENAI_BASE_URL%/}"
  # Ensure /v1 suffix
  if [[ "$BASE" != */v1 ]]; then BASE="$BASE/v1"; fi

  echo "[doghouse] Configuring OpenAI baseUrl -> $BASE"
  /usr/local/bin/moltbot config set models.providers.openai.baseUrl "$BASE" || true
  /usr/local/bin/moltbot config set models.providers.openai.apiKey "ooba" || true
fi

exec "$@"
