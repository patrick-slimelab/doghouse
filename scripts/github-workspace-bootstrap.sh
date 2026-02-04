#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a per-dog GitHub workspace repo and sync it into the live OpenClaw workspace.
#
# What it does:
# - Ensures `gh` is authenticated (via GH_TOKEN if available).
# - Ensures a PRIVATE repo exists: $DOGHOUSE_GITHUB_OWNER/$DOGHOUSE_WORKSPACE_REPO
# - Seeds it from slimelab-ai/openclaw-workspace (NOT a fork; private forks aren't allowed)
# - Adds slimelab repo as `upstream` remote for future merges
# - Syncs repo's ./workspace/ -> $DOGHOUSE_WORKSPACE (backing up existing workspace first)
#

OWNER="${DOGHOUSE_GITHUB_OWNER:-cyberscoob}"
REPO_NAME="${DOGHOUSE_WORKSPACE_REPO:-openclaw-workspace}"
UPSTREAM_URL="${DOGHOUSE_WORKSPACE_UPSTREAM_URL:-https://github.com/slimelab-ai/openclaw-workspace.git}"
BRANCH="${DOGHOUSE_WORKSPACE_BRANCH:-main}"

LIVE_WORKSPACE="${DOGHOUSE_WORKSPACE:?DOGHOUSE_WORKSPACE must be set}"

REPO_DIR="${DOGHOUSE_WORKSPACE_REPO_DIR:-/home/scoob/.openclaw/workspace-repo}"

log() { echo "[github-workspace] $*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "[github-workspace] ERROR: missing $1" >&2; exit 1; }
}

need git
need gh
need rsync

# Auth: prefer GH_TOKEN (env) for non-interactive login.
if gh auth status -h "${GH_HOST:-github.com}" >/dev/null 2>&1; then
  log "gh already authenticated"
else
  if [[ -n "${GH_TOKEN:-}" ]]; then
    log "Authenticating gh non-interactively using GH_TOKEN"
    printf '%s' "$GH_TOKEN" | gh auth login -h "${GH_HOST:-github.com}" --with-token >/dev/null 2>&1 || true
  fi

  if ! gh auth status -h "${GH_HOST:-github.com}" >/dev/null 2>&1; then
    log "WARN: gh is not authenticated. To finish setup, exec into container and run: gh auth login"
    return 0
  fi
fi

mkdir -p "$(dirname "$REPO_DIR")"

# Ensure private repo exists (NOT a fork).
if gh repo view "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
  log "Repo exists: $OWNER/$REPO_NAME"
else
  log "Creating private repo: $OWNER/$REPO_NAME"
  gh repo create "$OWNER/$REPO_NAME" --private --confirm >/dev/null

  # Seed from upstream: clone upstream and push all refs.
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  git clone --quiet "$UPSTREAM_URL" "$tmp/src"
  pushd "$tmp/src" >/dev/null

  # Set origin to the new private repo (use ssh if possible; fall back to https).
  origin_ssh="git@github.com:$OWNER/$REPO_NAME.git"
  origin_https="https://github.com/$OWNER/$REPO_NAME.git"

  if git ls-remote "$origin_ssh" >/dev/null 2>&1; then
    git remote set-url origin "$origin_ssh"
  else
    git remote set-url origin "$origin_https"
  fi

  # Push all branches/tags
  git push --quiet origin --all
  git push --quiet origin --tags
  popd >/dev/null

  log "Seeded $OWNER/$REPO_NAME from $UPSTREAM_URL"
fi

# Clone/update local working copy.
if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "Cloning $OWNER/$REPO_NAME -> $REPO_DIR"
  git clone --quiet "https://github.com/$OWNER/$REPO_NAME.git" "$REPO_DIR" || git clone --quiet "git@github.com:$OWNER/$REPO_NAME.git" "$REPO_DIR"
fi

pushd "$REPO_DIR" >/dev/null

# Ensure remotes
if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream "$UPSTREAM_URL"
else
  git remote add upstream "$UPSTREAM_URL"
fi

# Ensure origin is correct
if git remote get-url origin >/dev/null 2>&1; then
  :
else
  git remote add origin "https://github.com/$OWNER/$REPO_NAME.git"
fi

git fetch --quiet origin || true
git fetch --quiet upstream || true

git checkout -q "$BRANCH" || git checkout -q -b "$BRANCH" "origin/$BRANCH"

git pull --quiet --ff-only origin "$BRANCH" 2>/dev/null || true

# Sync ./workspace -> LIVE_WORKSPACE
if [[ ! -d workspace ]]; then
  log "ERROR: repo has no ./workspace directory (expected from slimelab-ai/openclaw-workspace)"
  exit 1
fi

# Backup current workspace (if non-empty)
if [[ -d "$LIVE_WORKSPACE" ]] && [[ -n "$(ls -A "$LIVE_WORKSPACE" 2>/dev/null || true)" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="${LIVE_WORKSPACE%/}.bak.$ts"
  log "Backing up existing workspace -> $backup"
  cp -a "$LIVE_WORKSPACE" "$backup" || true
fi

log "Syncing repo workspace/ -> $LIVE_WORKSPACE"
mkdir -p "$LIVE_WORKSPACE"
rsync -a --delete --exclude 'memory/' --exclude 'MEMORY.md' "workspace/" "$LIVE_WORKSPACE/"

log "OK"

popd >/dev/null
