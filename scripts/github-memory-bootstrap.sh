#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a per-dog PRIVATE memory repo and link it into the live workspace.
#
# Creates/ensures: $DOGHOUSE_GITHUB_OWNER/openclaw-memory (private)
# Clones to: $DOGHOUSE_MEMORY_REPO_DIR
# Ensures files exist: memory/ (dir), MEMORY.md
# Symlinks into workspace:
#   $DOGHOUSE_WORKSPACE/memory  -> $MEM_REPO_DIR/memory
#   $DOGHOUSE_WORKSPACE/MEMORY.md -> $MEM_REPO_DIR/MEMORY.md

OWNER="${DOGHOUSE_GITHUB_OWNER:-cyberscoob}"
REPO_NAME="${DOGHOUSE_MEMORY_REPO:-openclaw-memory}"
BRANCH="${DOGHOUSE_MEMORY_BRANCH:-main}"

WORKSPACE_DIR="${DOGHOUSE_WORKSPACE:?DOGHOUSE_WORKSPACE must be set}"
MEM_REPO_DIR="${DOGHOUSE_MEMORY_REPO_DIR:-/home/scoob/.openclaw/memory-repo}"

log() { echo "[github-memory] $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "[github-memory] ERROR: missing $1" >&2; exit 1; }; }

need git
need gh

if ! gh auth status -h "${GH_HOST:-github.com}" >/dev/null 2>&1; then
  if [[ -n "${GH_TOKEN:-}" ]]; then
    log "Authenticating gh non-interactively using GH_TOKEN"
    printf '%s' "$GH_TOKEN" | gh auth login -h "${GH_HOST:-github.com}" --with-token >/dev/null 2>&1 || true
  fi
fi

if ! gh auth status -h "${GH_HOST:-github.com}" >/dev/null 2>&1; then
  log "WARN: gh is not authenticated; skipping memory repo bootstrap"
  exit 0
fi

if gh repo view "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
  log "Repo exists: $OWNER/$REPO_NAME"
else
  log "Creating private repo: $OWNER/$REPO_NAME"
  gh repo create "$OWNER/$REPO_NAME" --private --confirm >/dev/null

  # Initialize with minimal structure
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/src/memory"
  cat > "$tmp/src/MEMORY.md" <<'EOF'
# MEMORY.md

Long-term notes.
EOF
  pushd "$tmp/src" >/dev/null
  git init -q
  git checkout -q -b "$BRANCH"
  git add -A
  git -c user.email="doghouse@local" -c user.name="doghouse" commit -q -m "Initialize memory repo"
  git remote add origin "https://github.com/$OWNER/$REPO_NAME.git"
  git push -q -u origin "$BRANCH"
  popd >/dev/null
fi

# Clone if needed
if [[ ! -d "$MEM_REPO_DIR/.git" ]]; then
  mkdir -p "$(dirname "$MEM_REPO_DIR")"
  log "Cloning memory repo -> $MEM_REPO_DIR"
  git clone --quiet "https://github.com/$OWNER/$REPO_NAME.git" "$MEM_REPO_DIR"
fi

pushd "$MEM_REPO_DIR" >/dev/null

git fetch --quiet origin || true

git checkout -q "$BRANCH" 2>/dev/null || git checkout -q -b "$BRANCH"

git pull --quiet --ff-only origin "$BRANCH" 2>/dev/null || true

mkdir -p memory
[[ -f MEMORY.md ]] || printf '# MEMORY.md\n\nLong-term notes.\n' > MEMORY.md

popd >/dev/null

# Link into workspace
mkdir -p "$WORKSPACE_DIR"

# Replace existing paths if they are non-symlink or wrong
if [[ -e "$WORKSPACE_DIR/memory" && ! -L "$WORKSPACE_DIR/memory" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  mv "$WORKSPACE_DIR/memory" "$WORKSPACE_DIR/memory.bak.$ts" || true
fi
ln -sfn "$MEM_REPO_DIR/memory" "$WORKSPACE_DIR/memory"

if [[ -e "$WORKSPACE_DIR/MEMORY.md" && ! -L "$WORKSPACE_DIR/MEMORY.md" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  mv "$WORKSPACE_DIR/MEMORY.md" "$WORKSPACE_DIR/MEMORY.md.bak.$ts" || true
fi
ln -sfn "$MEM_REPO_DIR/MEMORY.md" "$WORKSPACE_DIR/MEMORY.md"

log "OK: memory linked into workspace"
