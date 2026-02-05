#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
CFG_PATH="${OPENCLAW_CONFIG_PATH:-$STATE_DIR/openclaw.json}"

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

# Set MongoDB connection details early (needed for matrix-indexer CLI tools)
export MONGODB_URI="mongodb://mongo:27017"
export MONGODB_DB="matrix_index"

# MediaWiki (reuse Matrix creds by default)
DEFAULT_MEDIAWIKI_URL="https://cclub.cs.wmich.edu/w/api.php"

# Username is Matrix localpart (e.g. @scooby:server -> scooby)
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

# Default MediaWiki API endpoint (canonical API is usually /w/api.php)
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

# Workspace root. We intentionally default to /home/scoob to match legacy layout.
WORKSPACE_DIR="${DOGHOUSE_WORKSPACE:-/home/scoob}"

# Ensure state + workspace dirs exist + are writable by scoob
mkdir -p "$STATE_DIR" "$WORKSPACE_DIR"

# If the volume contains old root-owned/other-uid files, try to fix ownership.
# Some Docker setups can emit noisy EPERM/EACCES for unreadable entries; that's OK.
chown -R scoob:scoob "$STATE_DIR" "$WORKSPACE_DIR" 2>/dev/null || true

# Hardening: ensure config file perms are sane (gateway must be able to read it)
if [[ -f "$CFG_PATH" ]]; then
  chown scoob:scoob "$CFG_PATH" 2>/dev/null || true
  chmod 600 "$CFG_PATH" 2>/dev/null || true
fi
chmod 700 "$STATE_DIR" 2>/dev/null || true

# --- Dongometer auto-start (managed inside container, no systemd) ---
if [[ -x /home/scoob/dongometer/dongometerctl ]]; then
  echo [doghouse] Auto-starting dongometer
  gosu scoob /home/scoob/dongometer/dongometerctl restart || true
fi

# Configure SSH if authorized_keys secret is present
if [[ -f /run/secrets/authorized_keys ]]; then
  echo "[doghouse] Setting up SSH authorized_keys in /tmp/ssh..."
  rm -rf /tmp/ssh
  mkdir -p /tmp/ssh
  cat /run/secrets/authorized_keys > /tmp/ssh/scoob
  chmod 600 /tmp/ssh/scoob
  chown scoob:scoob /tmp/ssh/scoob
  
  # Start sshd in background (as root, before dropping privs)
  echo "[doghouse] Starting sshd on port 2222..."
  /usr/sbin/sshd -D -e &
fi

# COPY GITHUB KEY TO ~/.ssh IF PRESENT
if [[ -f /run/secrets/id_ed25519 ]]; then
  echo "[doghouse] Setting up GitHub SSH key in ~/.ssh..."
  mkdir -p /home/scoob/.ssh
  
  # Remove any stale keys first
  rm -f /home/scoob/.ssh/id_ed25519 /home/scoob/.ssh/id_ed25519.pub
  
  # Copy private key
  cat /run/secrets/id_ed25519 > /home/scoob/.ssh/id_ed25519
  chmod 600 /home/scoob/.ssh/id_ed25519
  chown scoob:scoob /home/scoob/.ssh/id_ed25519
  
  # Regenerate public key from private key
  ssh-keygen -y -f /home/scoob/.ssh/id_ed25519 > /home/scoob/.ssh/id_ed25519.pub
  chmod 644 /home/scoob/.ssh/id_ed25519.pub
  chown scoob:scoob /home/scoob/.ssh/id_ed25519.pub
  echo "[doghouse] SSH public key: $(cat /home/scoob/.ssh/id_ed25519.pub)"
  
  # Add github.com to known_hosts to avoid prompt
  ssh-keyscan github.com > /home/scoob/.ssh/known_hosts 2>/dev/null
  chown scoob:scoob /home/scoob/.ssh/known_hosts
fi

# Configure git to trust all directories (prevents "dubious ownership" errors)
echo "[doghouse] Configuring git safe.directory"
gosu scoob git config --global --add safe.directory '*'

# --- GitHub CLI auth + workspace repo bootstrap ---
# Prefer GH_TOKEN from docker secret (and/or env_file) for non-interactive auth.
if [[ -f /run/secrets/gh_token ]]; then
  export GH_TOKEN="$(read_secret /run/secrets/gh_token)"
  echo "[doghouse] GH_TOKEN loaded from docker secret"
fi

# Ensure gh auth is initialized for the scoob user (creates ~/.config/gh/hosts.yml)
if command -v gh >/dev/null 2>&1; then
  if ! gosu scoob gh auth status -h "${GH_HOST:-github.com}" >/dev/null 2>&1; then
    if [[ -n "${GH_TOKEN:-}" ]]; then
      echo "[doghouse] Pre-authenticating gh for scoob (non-interactive)"
      # Do NOT echo token
      gosu scoob bash -lc 'printf "%s" "$GH_TOKEN" | gh auth login -h "${GH_HOST:-github.com}" --with-token >/dev/null 2>&1 || true'
    else
      echo "[doghouse] WARN: GH_TOKEN not set; gh will require manual login (exec in and run: gh auth login)"
    fi
  fi
fi

# Bootstrap the private workspace repo (best-effort). This makes $WORKSPACE_DIR a git-backed checkout.
if [[ -x /opt/doghouse/scripts/github-workspace-bootstrap.sh ]]; then
  echo "[doghouse] Bootstrapping GitHub workspace repo (rebase policy) -> $WORKSPACE_DIR"
  # Log bootstrap output for debugging
  gosu scoob env DOGHOUSE_WORKSPACE="$WORKSPACE_DIR" bash -lc '/opt/doghouse/scripts/github-workspace-bootstrap.sh' > /tmp/github-workspace-bootstrap.log 2>&1 || true
  echo "[doghouse] Workspace bootstrap log: /tmp/github-workspace-bootstrap.log"

  # Link + bootstrap memory repo (separate private repo) and start autosync
  if [[ -x /opt/doghouse/scripts/github-memory-bootstrap.sh ]]; then
    echo "[doghouse] Bootstrapping GitHub memory repo -> $WORKSPACE_DIR (symlinks)"
    gosu scoob env DOGHOUSE_WORKSPACE="$WORKSPACE_DIR" bash -lc '/opt/doghouse/scripts/github-memory-bootstrap.sh' || true

    if [[ -x /opt/doghouse/scripts/github-memory-autocommit.sh ]]; then
      echo "[doghouse] Starting memory autosync commits"
      gosu scoob env DOGHOUSE_WORKSPACE="$WORKSPACE_DIR" bash -lc 'nohup /opt/doghouse/scripts/github-memory-autocommit.sh >/tmp/github-memory-autocommit.log 2>&1 &' || true
    fi
  fi

  # Start background autosync commits for workspace
  if [[ -x /opt/doghouse/scripts/github-workspace-autocommit.sh ]]; then
    echo "[doghouse] Starting workspace autosync commits"
    gosu scoob env DOGHOUSE_WORKSPACE="$WORKSPACE_DIR" bash -lc 'nohup /opt/doghouse/scripts/github-workspace-autocommit.sh >/tmp/github-workspace-autocommit.log 2>&1 &' || true
  fi
fi

# One-time non-interactive bootstrap (no TUI)
if [[ ! -f "$CFG_PATH" ]]; then
  echo "[doghouse] First run: openclaw setup"
  gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw setup --workspace "$WORKSPACE_DIR"
fi

# Enforce workspace every boot (fixes legacy configs pointing to /home/node/clawd)
echo "[doghouse] Enforcing agents.defaults.workspace=$WORKSPACE_DIR"
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set agents.defaults.workspace "$WORKSPACE_DIR" || true
# Ensure gateway is allowed to run (set unconditionally to avoid restart loop)
echo "[doghouse] Setting gateway.mode=local"
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set gateway.mode local || true


# Enforce Full Auto (no ask, no security restrictions)
echo "[doghouse] Enforcing Full Auto (tools.exec.ask=off, tools.exec.security=full)"
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set tools.exec.ask off || true
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set tools.exec.security full || true

# Open DMs and Group channels for Scoob on Discord + Matrix
echo "[doghouse] Configuring Discord channels: open"
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.discord.enabled true || true
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.discord.dm.policy "open" || true
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.discord.dm.allowFrom "['*']" || true
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.discord.groupPolicy "open" || true

echo "[doghouse] Configuring Discord guilds: mention required (with patterns)"
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set 'channels.discord.guilds.*.requireMention' false || true

echo "[doghouse] Configuring mention patterns: scoo+b, scooby, scoob"
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set messages.groupChat.mentionPatterns '["scoo+b", "scooby", "scoob"]' || true

# Message queueing (prevents rapid double-replies; especially helpful on Matrix)
echo "[doghouse] Configuring routing.queue (collect + debounce)"
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set routing.queue '{ mode: "collect", debounceMs: 1500, cap: 20, drop: "summarize", byChannel: { matrix: "collect", discord: "collect" } }' --json || true

echo "[doghouse] Configuring Matrix channels: open"
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.matrix.enabled true || true
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.matrix.dm.policy "open" || true
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.matrix.dm.allowFrom "['*']" || true
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.matrix.groupPolicy "open" || true

echo "[doghouse] Configuring Matrix groups: mention required (with patterns)"
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set 'channels.matrix.groups.*.requireMention' true || true

# Ensure gateway is allowed to run
MODE="$(gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config get gateway.mode 2>/dev/null || true)"
if [[ -z "${MODE// }" || "$MODE" == "null" ]]; then
  echo "[doghouse] Setting gateway.mode=local"
  gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set gateway.mode local || true
fi

# Wire Scoob to the host ooba OpenAI-compatible API by default
if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
  BASE="${OPENAI_BASE_URL%/}"
  if [[ "$BASE" != */v1 ]]; then BASE="$BASE/v1"; fi

  echo "[doghouse] Configuring OpenAI provider -> $BASE"
  gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set models.providers.openai "{api: 'openai-completions', baseUrl: '$BASE', apiKey: 'ooba', models: []}" || true

  if [[ "${AUTO_DETECT_OPENAI_MODEL:-0}" == "1" ]]; then
  echo "[doghouse] Probing ooba for loaded model..."
  if MODEL_ID=$(curl -s "$BASE/models" | jq -r '.data[0].id // empty'); then
    if [[ -n "$MODEL_ID" ]]; then
      # IF the detected model is the long HF tag, switch it to 'heretic' alias if available
      if [[ "$MODEL_ID" == *"HERETIC"* ]]; then
         MODEL_ID="heretic"
      fi
      echo "[doghouse] Detected model: $MODEL_ID"
      gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set agents.defaults.model.primary "openai/$MODEL_ID" || true
    else
      echo "[doghouse] Warn: No models returned from $BASE/models"
    fi
  else
    echo "[doghouse] Warn: Failed to query $BASE/models (is ooba running?)"
  fi
  fi
fi

# Configure Ollama provider (port 11434)
FORCE_DEFAULT_MODEL_OLLAMA="${FORCE_DEFAULT_MODEL_OLLAMA:-ollama/gpt-oss:20b}"

echo "[doghouse] Configuring Ollama provider -> http://host.docker.internal:11434/v1"
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set models.providers.ollama "{
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
      id: 'glm-4.7-flash',
      name: 'glm-4.7-flash',
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

# Setup Matrix Indexer (C#) credentials and start it
echo "[doghouse] Checking for Matrix Indexer binary..."
if [ -f /usr/local/bin/matrix-indexer ]; then
  echo "[doghouse] Found matrix-indexer, configuring..."
  # Use environment variables loaded from secrets
  if [[ -n "${MATRIX_HOMESERVER:-}" ]]; then
    echo "[doghouse] MATRIX_HOMESERVER is set, proceeding..."
    # Ensure working directory exists for state file
    mkdir -p /home/scoob/matrix-indexer
    chown scoob:scoob /home/scoob/matrix-indexer
    
    # Generate .env file with correct mongo host
    cat > /home/scoob/matrix-indexer/.env << EOF
MATRIX_HOMESERVER=${MATRIX_HOMESERVER}
MATRIX_USER_ID=${MATRIX_USER_ID}
MATRIX_PASSWORD=${MATRIX_PASSWORD}
MONGODB_URI=mongodb://mongo:27017
MONGODB_DB=matrix_index
EOF
    chown scoob:scoob /home/scoob/matrix-indexer/.env
    chmod 600 /home/scoob/matrix-indexer/.env
    
    echo "[doghouse] Starting Matrix Indexer in background..."
    # Using nohup to run in background, detached from this shell
    gosu scoob bash -c "cd /home/scoob/matrix-indexer && set -a && source .env && set +a && nohup /usr/local/bin/matrix-indexer > /tmp/indexer.log 2>&1 &" &
    sleep 1
    echo "[doghouse] Matrix Indexer started (PID check in 2 seconds)"
    echo "[doghouse] Starting Matrix maintenance (stale backfill reaper + room cache)"
    gosu scoob bash -lc 'nohup /usr/local/bin/matrix-maintenance > /tmp/matrix-maintenance.log 2>&1 &'
  else
    echo "[doghouse] Warn: MATRIX_HOMESERVER not set, skipping indexer start."
  fi
else
  echo "[doghouse] Matrix Indexer binary not found at /usr/local/bin/matrix-indexer"
fi

# Configure Discord/Matrix credentials directly in config (env vars don't persist through gosu)
if [[ -n "${DISCORD_BOT_TOKEN:-}" ]]; then
  echo "[doghouse] Setting Discord bot token in config..."
  gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.discord.token "${DISCORD_BOT_TOKEN}" || true
fi

if [[ -n "${MATRIX_HOMESERVER:-}" ]]; then
  echo "[doghouse] Setting Matrix homeserver in config..."
  gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.matrix.homeserver "${MATRIX_HOMESERVER}" || true
fi

if [[ -n "${MATRIX_USER_ID:-}" ]]; then
  echo "[doghouse] Setting Matrix user ID in config..."
  gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.matrix.userId "${MATRIX_USER_ID}" || true
fi

if [[ -n "${MATRIX_PASSWORD:-}" ]]; then
  echo "[doghouse] Setting Matrix password in config..."
  gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set channels.matrix.password "${MATRIX_PASSWORD}" || true
fi


# Force default model so we don't accidentally use a cloud endpoint that can rate-limit (HTTP 429)
gosu scoob env HOME=/home/scoob OPENCLAW_STATE_DIR=/home/scoob/.openclaw OPENCLAW_CONFIG_PATH=/home/scoob/.openclaw/openclaw.json /usr/local/bin/openclaw config set agents.defaults.model.primary "${FORCE_DEFAULT_MODEL_OLLAMA}" || true

# Convenience: expose installed helper scripts on PATH (survive container recreate)
if [[ -f /home/scoob/.openclaw/skills/mediawiki-cclub/scripts/mediawiki.sh ]]; then
  ln -sf /home/scoob/.openclaw/skills/mediawiki-cclub/scripts/mediawiki.sh /usr/local/bin/mediawiki
  chmod +x /usr/local/bin/mediawiki
fi
# Finally run the gateway as scoob
exec gosu scoob "$@"

