#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
CFG_PATH="${OPENCLAW_CONFIG_PATH:-$STATE_DIR/openclaw.json}"

# Compatibility shim: older configs/scripts may still reference /home/scoob.
# Create a stable alias so anything trying to mkdir /home/scoob doesn't explode under the scrappy user.
if [[ ! -e /home/scoob ]]; then
  ln -s /home/scrappy /home/scoob || true
fi

read_secret() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  # Trim trailing newlines
  tr -d '\r
' < "$path"
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
  export OPENCLAW_GATEWAY_TOKEN="$gt"
  echo "[doghouse] Loaded OPENCLAW_GATEWAY_TOKEN from docker secret"
fi

# Web search (Brave)
if bk="$(read_secret /run/secrets/brave_api_key)"; then
  export BRAVE_API_KEY="$bk"
  echo "[doghouse] Loaded BRAVE_API_KEY from docker secret"
fi

# Set MongoDB connection details early
export MONGODB_URI="mongodb://mongo:27017"
export MONGODB_DB="matrix_index"

# MediaWiki (reuse Matrix creds by default)
DEFAULT_MEDIAWIKI_URL="https://cclub.cs.wmich.edu/w/api.php"

# Username is Matrix localpart (e.g. @scrappy:server -> scrappy)
# Prefer explicit MediaWiki creds (docker secrets), otherwise fall back to Matrix creds
if mwu="$(read_secret /run/secrets/mediawiki_user 2>/dev/null || true)"; then
  if [[ -n "$mwu" ]]; then export MEDIAWIKI_USER="$mwu"; fi
fi
if mwp="$(read_secret /run/secrets/mediawiki_password 2>/dev/null || true)"; then
  if [[ -n "$mwp" ]]; then export MEDIAWIKI_PASSWORD="$mwp"; fi
fi

if [[ -z "${MEDIAWIKI_USER:-}" && -n "${MATRIX_USER_ID:-}" ]]; then
  MEDIAWIKI_USER="${MATRIX_USER_ID#@}"
  MEDIAWIKI_USER="${MEDIAWIKI_USER%%:*}"
  export MEDIAWIKI_USER
fi
if [[ -z "${MEDIAWIKI_PASSWORD:-}" && -n "${MATRIX_PASSWORD:-}" ]]; then
  export MEDIAWIKI_PASSWORD="${MATRIX_PASSWORD}"
fi
if mwurl="$(read_secret /run/secrets/mediawiki_url 2>/dev/null || true)"; then
  if [[ -n "$mwurl" ]]; then
    export MEDIAWIKI_URL="$mwurl"
    echo "[doghouse] Loaded MEDIAWIKI_URL from docker secret"
  fi
fi

# Default MediaWiki API endpoint (MediaWiki canonical API is usually /w/api.php)
if [[ -z "${MEDIAWIKI_URL:-}" ]]; then
  export MEDIAWIKI_URL="$DEFAULT_MEDIAWIKI_URL"
fi

# Write secrets to /etc/profile.d so they're available in ALL login shells (including SSH)
SECRETS_FILE="/etc/profile.d/matrix-env.sh"
{
  echo "#!/bin/bash"
  echo "# Matrix Indexer Environment Variables (auto-generated at container startup)"
  [[ -n "${MATRIX_HOMESERVER:-}" ]] && echo "export MATRIX_HOMESERVER='${MATRIX_HOMESERVER}'"
  [[ -n "${MATRIX_USER_ID:-}" ]] && echo "export MATRIX_USER_ID='${MATRIX_USER_ID}'"
  [[ -n "${MATRIX_PASSWORD:-}" ]] && echo "export MATRIX_PASSWORD='${MATRIX_PASSWORD}'"
  [[ -n "${DISCORD_BOT_TOKEN:-}" ]] && echo "export DISCORD_BOT_TOKEN='${DISCORD_BOT_TOKEN}'"
  [[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]] && echo "export OPENCLAW_GATEWAY_TOKEN='${OPENCLAW_GATEWAY_TOKEN}'"
  [[ -n "${MEDIAWIKI_URL:-}" ]] && echo "export MEDIAWIKI_URL='${MEDIAWIKI_URL}'"
  [[ -n "${MEDIAWIKI_USER:-}" ]] && echo "export MEDIAWIKI_USER='${MEDIAWIKI_USER}'"
  [[ -n "${MEDIAWIKI_PASSWORD:-}" ]] && echo "export MEDIAWIKI_PASSWORD='${MEDIAWIKI_PASSWORD}'"
  [[ -n "${MONGODB_URI:-}" ]] && echo "export MONGODB_URI='${MONGODB_URI}'"
  [[ -n "${MONGODB_DB:-}" ]] && echo "export MONGODB_DB='${MONGODB_DB}'"
} > "$SECRETS_FILE"
chmod 644 "$SECRETS_FILE"
echo "[doghouse] Secrets written to $SECRETS_FILE (sourced by all login shells)"

WORKSPACE_DIR="${DOGHOUSE_WORKSPACE:-$HOME/clawd}"

# Ensure state + workspace dirs exist + are writable by scrappy
mkdir -p "$STATE_DIR" "$WORKSPACE_DIR"

# If the volume contains old root-owned/other-uid files, try to fix ownership.
# Some Docker setups can emit noisy EPERM/EACCES for unreadable entries; that's OK.
chown -R scrappy:scrappy "$STATE_DIR" "$WORKSPACE_DIR" 2>/dev/null || true

# Configure SSH if authorized_keys secret is present
if [[ -f /run/secrets/authorized_keys ]]; then
  echo "[doghouse] Setting up SSH authorized_keys in /tmp/ssh..."
  rm -rf /tmp/ssh
  mkdir -p /tmp/ssh
  cat /run/secrets/authorized_keys > /tmp/ssh/scrappy
  chmod 600 /tmp/ssh/scrappy
  chown scrappy:scrappy /tmp/ssh/scrappy
  
  # Start sshd in background (as root, before dropping privs)
  echo "[doghouse] Starting sshd on port 2222..."
  /usr/sbin/sshd -D -e &
fi

# COPY GITHUB KEY TO ~/.ssh IF PRESENT
if [[ -f /run/secrets/id_ed25519 ]]; then
  echo "[doghouse] Setting up GitHub SSH key in ~/.ssh..."
  mkdir -p /home/scrappy/.ssh
  
  # Remove any stale keys first
  rm -f /home/scrappy/.ssh/id_ed25519 /home/scrappy/.ssh/id_ed25519.pub
  
  # Copy private key
  cat /run/secrets/id_ed25519 > /home/scrappy/.ssh/id_ed25519
  chmod 600 /home/scrappy/.ssh/id_ed25519
  chown scrappy:scrappy /home/scrappy/.ssh/id_ed25519
  
  # Regenerate public key from private key
  ssh-keygen -y -f /home/scrappy/.ssh/id_ed25519 > /home/scrappy/.ssh/id_ed25519.pub
  chmod 644 /home/scrappy/.ssh/id_ed25519.pub
  chown scrappy:scrappy /home/scrappy/.ssh/id_ed25519.pub
  echo "[doghouse] SSH public key: $(cat /home/scrappy/.ssh/id_ed25519.pub)"
  
  # Add github.com to known_hosts to avoid prompt
  ssh-keyscan github.com > /home/scrappy/.ssh/known_hosts 2>/dev/null
  chown scrappy:scrappy /home/scrappy/.ssh/known_hosts
fi

# Configure git to trust all directories (prevents "dubious ownership" errors)
echo "[doghouse] Configuring git safe.directory"
gosu scrappy git config --global --add safe.directory '*'

# AUTO-LOGIN GH CLI IF TOKEN PRESENT
if [[ -f /run/secrets/gh_token ]]; then
  echo "[doghouse] Loading GH token..."
  # Set as env var (gh auth login --with-token was hanging, env var is sufficient)
  export GH_TOKEN="$(read_secret /run/secrets/gh_token)"
  echo "[doghouse] GH_TOKEN loaded"
fi

# Migrate legacy paths in existing config/state
if [[ -f "$CFG_PATH" ]]; then
  sed -i 's#/home/scoob#/home/scrappy#g' "$CFG_PATH" 2>/dev/null || true
fi

# One-time non-interactive bootstrap (no TUI)
if [[ ! -f "$CFG_PATH" ]]; then
  echo "[doghouse] First run: openclaw setup"
  gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw setup --workspace "$WORKSPACE_DIR"
fi

# Enforce workspace every boot (fixes legacy configs pointing to /home/node/clawd)
echo "[doghouse] Enforcing agents.defaults.workspace=$WORKSPACE_DIR"
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set agents.defaults.workspace "$WORKSPACE_DIR" || true
# Ensure gateway is allowed to run (set unconditionally to avoid restart loop)
echo "[doghouse] Setting gateway.mode=local"
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set gateway.mode local || true


# Enforce Full Auto (no ask, no security restrictions)
echo "[doghouse] Enforcing Full Auto (tools.exec.ask=off, tools.exec.security=full)"
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set tools.exec.ask off || true
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set tools.exec.security full || true

# Open DMs and Group channels for Scoob on Discord + Matrix
echo "[doghouse] Configuring Discord channels: open"
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.discord.enabled true || true
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.discord.dm.policy "open" || true
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.discord.dm.allowFrom "['*']" || true
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.discord.groupPolicy "open" || true

echo "[doghouse] Configuring Discord guilds: mention required (with patterns)"
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set 'channels.discord.guilds.*.requireMention' false || true

echo "[doghouse] Configuring mention patterns: scrap+?"
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set messages.groupChat.mentionPatterns '["scrap+?y", "scrappy"]' || true

echo "[doghouse] Configuring Matrix channels: open"
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.matrix.enabled true || true
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.matrix.dm.policy "open" || true
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.matrix.dm.allowFrom "['*']" || true
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.matrix.groupPolicy "open" || true

echo "[doghouse] Configuring Matrix groups: mention required (with patterns)"
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set 'channels.matrix.groups.*.requireMention' true || true

# Ensure gateway is allowed to run
MODE="$(gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config get gateway.mode 2>/dev/null || true)"
if [[ -z "${MODE// }" || "$MODE" == "null" ]]; then
  echo "[doghouse] Setting gateway.mode=local"
  gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set gateway.mode local || true
fi

# Wire Scoob to the host ooba OpenAI-compatible API by default
if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
  BASE="${OPENAI_BASE_URL%/}"
  if [[ "$BASE" != */v1 ]]; then BASE="$BASE/v1"; fi

  echo "[doghouse] Configuring OpenAI provider -> $BASE"
  gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set models.providers.openai "{api: 'openai-completions', baseUrl: '$BASE', apiKey: 'ooba', models: []}" || true

  echo "[doghouse] Probing ooba for loaded model..."
  if MODEL_ID=$(curl -s "$BASE/models" | jq -r '.data[0].id // empty'); then
    if [[ -n "$MODEL_ID" ]]; then
      # IF the detected model is the long HF tag, switch it to 'heretic' alias if available
      if [[ "$MODEL_ID" == *"HERETIC"* ]]; then
         MODEL_ID="heretic"
      fi
      echo "[doghouse] Detected model: $MODEL_ID"
      gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set agents.defaults.model.primary "openai/$MODEL_ID" || true
    else
      echo "[doghouse] Warn: No models returned from $BASE/models"
    fi
  else
    echo "[doghouse] Warn: Failed to query $BASE/models (is ooba running?)"
  fi
fi

# Configure Ollama provider (port 11434)
echo "[doghouse] Configuring Ollama provider -> http://host.docker.internal:11434/v1"
gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set models.providers.ollama "{
  baseUrl: 'http://host.docker.internal:11434/v1',
  apiKey: 'ollama-local',
  api: 'openai-completions',
  models: [
    {
      id: 'gpt-oss:120b',
      name: 'gpt-oss:120b',
      reasoning: true,
      input: ['text'],
      contextWindow: 131072,
      maxTokens: 1310720
    },
    {
      id: 'gpt-oss:20b',
      name: 'gpt-oss:20b',
      reasoning: true,
      input: ['text'],
      contextWindow: 131072,
      maxTokens: 1310720
    },
    {
      id: 'qwen2.5:32b-instruct',
      name: 'qwen2.5:32b-instruct',
      reasoning: false,
      input: ['text'],
      contextWindow: 32768,
      maxTokens: 32768
    },
    {
      id: 'heretic',
      name: 'heretic',
      reasoning: true,
      input: ['text'],
      contextWindow: 65536,
      maxTokens: 655360
    }
  ]
}" || true

# (scrappy) No Matrix indexer in this image
# Setup Discord Indexer (.NET) credentials and start it
echo "[doghouse] Checking for Discord Indexer binary..."
if [ -f /usr/local/bin/discord-indexer ]; then
  echo "[doghouse] Found discord-indexer, configuring..."
  if [[ -n "${DISCORD_BOT_TOKEN:-}" ]]; then
    mkdir -p /home/scrappy/discord-indexer
    chown scrappy:scrappy /home/scrappy/discord-indexer
    cat > /home/scrappy/discord-indexer/.env << EOF
DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}
DISCORD_GUILD_IDS=${DISCORD_GUILD_IDS:-}
MONGODB_URI=mongodb://mongo:27017
MONGODB_DB=discord_index
EOF
    chown scrappy:scrappy /home/scrappy/discord-indexer/.env
    chmod 600 /home/scrappy/discord-indexer/.env
    echo "[doghouse] Starting Discord Indexer in background..."
    gosu scrappy bash -c "cd /home/scrappy/discord-indexer && set -a && source .env && set +a && nohup /usr/local/bin/discord-indexer > /tmp/discord-indexer.log 2>&1 &" &
    sleep 1
    echo "[doghouse] Discord Indexer started (PID check in 2 seconds)"
  else
    echo "[doghouse] Warn: DISCORD_BOT_TOKEN not set, skipping discord indexer start."
  fi
else
  echo "[doghouse] Discord Indexer binary not found at /usr/local/bin/discord-indexer"
fi

# Configure Discord/Matrix credentials directly in config (env vars don't persist through gosu)
if [[ -n "${DISCORD_BOT_TOKEN:-}" ]]; then
  echo "[doghouse] Setting Discord bot token in config..."
  gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.discord.token "${DISCORD_BOT_TOKEN}" || true
fi

if [[ -n "${MATRIX_HOMESERVER:-}" ]]; then
  echo "[doghouse] Setting Matrix homeserver in config..."
  gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.matrix.homeserver "${MATRIX_HOMESERVER}" || true
fi

if [[ -n "${MATRIX_USER_ID:-}" ]]; then
  echo "[doghouse] Setting Matrix user ID in config..."
  gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.matrix.userId "${MATRIX_USER_ID}" || true
fi

if [[ -n "${MATRIX_PASSWORD:-}" ]]; then
  echo "[doghouse] Setting Matrix password in config..."
  gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.matrix.password "${MATRIX_PASSWORD}" || true
fi

# Convenience: expose installed helper scripts on PATH (survive container recreate)
if [[ -f /home/scrappy/.openclaw/skills/mediawiki-cclub/scripts/mediawiki.sh ]]; then
  ln -sf /home/scrappy/.openclaw/skills/mediawiki-cclub/scripts/mediawiki.sh /usr/local/bin/mediawiki
  chmod +x /usr/local/bin/mediawiki
fi
# Force default model so we don't accidentally use a cloud endpoint that can rate-limit (HTTP 429)
# (and so both doghouses use the same brain by default)
if [[ -n "${FORCE_DEFAULT_MODEL_OLLAMA:-}" ]]; then
  echo "[doghouse] Setting default model: ${FORCE_DEFAULT_MODEL_OLLAMA}"
  gosu scrappy env HOME=/home/scrappy OPENCLAW_STATE_DIR=/home/scrappy/.openclaw OPENCLAW_CONFIG_PATH=/home/scrappy/.openclaw/openclaw.json /usr/local/bin/openclaw config set agents.defaults.model.primary "${FORCE_DEFAULT_MODEL_OLLAMA}" || true
fi

# Finally run the gateway as scrappy
exec gosu scrappy "$@"

