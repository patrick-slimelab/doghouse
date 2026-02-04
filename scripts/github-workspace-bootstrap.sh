#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a per-dog PRIVATE workspace repo and make it the live OpenClaw workspace.
#
# Policy: rebase-based (clean stack of dog commits on top of a model baseline)
# - Keep a private repo under the dog's account (cannot be a private fork)
# - Add slimelab baseline as `upstream`
# - Rebase dog's branch onto upstream baseline branch
# - Force-push with lease
# - Ensure the LIVE workspace directory is a git checkout of the private repo

OWNER="${DOGHOUSE_GITHUB_OWNER:-cyberscoob}"
REPO_NAME="${DOGHOUSE_WORKSPACE_REPO:-openclaw-workspace}"
UPSTREAM_URL="${DOGHOUSE_WORKSPACE_UPSTREAM_URL:-https://github.com/slimelab-ai/openclaw-workspace.git}"

# The dog's working branch in the private repo.
BRANCH="${DOGHOUSE_WORKSPACE_BRANCH:-main}"

# The baseline branch to rebase onto, in the slimelab upstream repo.
# Examples: model/qwen3-coder-next-80b-a3b-f16, model/gpt-oss-20b
BASELINE_BRANCH="${DOGHOUSE_WORKSPACE_BASELINE_BRANCH:-main}"

LIVE_WORKSPACE="${DOGHOUSE_WORKSPACE:?DOGHOUSE_WORKSPACE must be set}"

log() { echo "[github-workspace] $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "[github-workspace] ERROR: missing $1" >&2; exit 1; }; }

need git
need gh

# Ensure gh auth (best-effort; if missing, skip bootstrap rather than crash container)
if ! gh auth status -h "${GH_HOST:-github.com}" >/dev/null 2>&1; then
  if [[ -n "${GH_TOKEN:-}" ]]; then
    log "Authenticating gh non-interactively using GH_TOKEN"
    printf '%s' "$GH_TOKEN" | gh auth login -h "${GH_HOST:-github.com}" --with-token >/dev/null 2>&1 || true
  fi
fi

if ! gh auth status -h "${GH_HOST:-github.com}" >/dev/null 2>&1; then
  log "WARN: gh is not authenticated; skipping workspace repo bootstrap (run: gh auth login)"
  exit 0
fi

# Ensure private repo exists (NOT a fork)
if gh repo view "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
  log "Repo exists: $OWNER/$REPO_NAME"
else
  log "Creating private repo: $OWNER/$REPO_NAME"
  gh repo create "$OWNER/$REPO_NAME" --private --confirm >/dev/null

  # Seed from upstream by mirroring refs
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  git clone --quiet "$UPSTREAM_URL" "$tmp/src"
  pushd "$tmp/src" >/dev/null

  origin_https="https://github.com/$OWNER/$REPO_NAME.git"
  git remote set-url origin "$origin_https"

  git push --quiet origin --all
  git push --quiet origin --tags
  popd >/dev/null

  log "Seeded $OWNER/$REPO_NAME from $UPSTREAM_URL"
fi

# Make LIVE_WORKSPACE a git checkout of the private repo.
# If it's not a git repo, back it up and clone into place.
if [[ ! -d "$LIVE_WORKSPACE/.git" ]]; then
  if [[ -d "$LIVE_WORKSPACE" ]] && [[ -n "$(ls -A "$LIVE_WORKSPACE" 2>/dev/null || true)" ]]; then
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="${LIVE_WORKSPACE%/}.bak.$ts"
    log "Backing up existing workspace -> $backup"
    mv "$LIVE_WORKSPACE" "$backup" || true
  fi
  mkdir -p "$(dirname "$LIVE_WORKSPACE")"
  log "Cloning private workspace repo into live workspace: $LIVE_WORKSPACE"
  git clone --quiet "https://github.com/$OWNER/$REPO_NAME.git" "$LIVE_WORKSPACE"
fi

pushd "$LIVE_WORKSPACE" >/dev/null

# Remotes
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "https://github.com/$OWNER/$REPO_NAME.git"
else
  git remote add origin "https://github.com/$OWNER/$REPO_NAME.git"
fi

if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream "$UPSTREAM_URL"
else
  git remote add upstream "$UPSTREAM_URL"
fi

# Ensure working branch exists
set +e
if ! git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git fetch --quiet origin "$BRANCH" 2>/dev/null || true
  if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    git checkout -q -b "$BRANCH" "origin/$BRANCH"
  else
    git checkout -q -b "$BRANCH"
  fi
else
  git checkout -q "$BRANCH"
fi
set -e

# Update from origin
git fetch --quiet origin || true
# Fast-forward local to origin if possible
git pull --quiet --ff-only origin "$BRANCH" 2>/dev/null || true

# Rebase onto upstream baseline
log "Fetching upstream baseline: $BASELINE_BRANCH"
git fetch --quiet upstream "$BASELINE_BRANCH" || true

if git show-ref --verify --quiet "refs/remotes/upstream/$BASELINE_BRANCH"; then
  log "Rebasing $BRANCH onto upstream/$BASELINE_BRANCH"
  if ! git rebase "upstream/$BASELINE_BRANCH"; then
    log "WARN: rebase failed; aborting rebase (manual conflict resolution needed)"
    git rebase --abort || true
    exit 0
  fi

  log "Pushing rebased branch to origin (force-with-lease)"
  git push --force-with-lease origin "$BRANCH"
else
  log "WARN: upstream baseline branch not found: $BASELINE_BRANCH"
fi

log "OK: live workspace is git-backed at $LIVE_WORKSPACE"

git remote -v | sed 's/^/[github-workspace] /'

git rev-parse --abbrev-ref HEAD | sed 's/^/[github-workspace] branch: /'

git rev-parse HEAD | sed 's/^/[github-workspace] head: /'

popd >/dev/null
