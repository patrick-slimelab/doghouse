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

# Ensure gh configures git credential helper (so `git push` works with GH_TOKEN-backed auth)
# Best-effort; ok if it fails.
(gh auth setup-git -h "${GH_HOST:-github.com}" >/dev/null 2>&1) || true

# Make LIVE_WORKSPACE a git checkout of the private repo.
# If it's not a git repo, back it up and clone into place.
# If it *is* a git repo but not the expected repo, move it aside and clone fresh.
expected_origin_a="https://github.com/$OWNER/$REPO_NAME.git"
expected_origin_b="git@github.com:$OWNER/$REPO_NAME.git"

if [[ -d "$LIVE_WORKSPACE/.git" ]]; then
  pushd "$LIVE_WORKSPACE" >/dev/null
  current_origin="$(git remote get-url origin 2>/dev/null || true)"
  popd >/dev/null

  if [[ -n "$current_origin" ]] && [[ "$current_origin" != "$expected_origin_a" ]] && [[ "$current_origin" != "$expected_origin_b" ]]; then
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="${LIVE_WORKSPACE%/}.legacy.$ts"
    log "WARN: $LIVE_WORKSPACE is a git repo but origin=$current_origin (expected $expected_origin_a). Moving aside -> $backup"
    mv "$LIVE_WORKSPACE" "$backup" || true
  fi
fi

if [[ ! -d "$LIVE_WORKSPACE/.git" ]]; then
  if [[ -d "$LIVE_WORKSPACE" ]] && [[ -n "$(ls -A "$LIVE_WORKSPACE" 2>/dev/null || true)" ]]; then
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="${LIVE_WORKSPACE%/}.bak.$ts"
    log "Backing up existing workspace -> $backup"
    mv "$LIVE_WORKSPACE" "$backup" || true
  fi
  mkdir -p "$(dirname "$LIVE_WORKSPACE")"
  log "Cloning private workspace repo into live workspace: $LIVE_WORKSPACE"
  git clone --quiet "$expected_origin_a" "$LIVE_WORKSPACE"
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

# Fetch latest refs
git fetch --quiet origin || true
log "Fetching upstream baseline: $BASELINE_BRANCH"
git fetch --quiet upstream "$BASELINE_BRANCH" || true

# Preserve whatever currently exists (in case this directory was previously used for something else)
current_head="$(git rev-parse HEAD 2>/dev/null || true)"
if [[ -n "$current_head" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  git branch "backup/legacy-$ts" "$current_head" >/dev/null 2>&1 || true
fi

# Force the working branch to exist and be checked out.
# If origin has the branch, base on that.
# Else, base on upstream baseline.
# Else, create an empty branch.
if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  log "Checking out $BRANCH from origin/$BRANCH"
  git checkout -q -B "$BRANCH" "origin/$BRANCH"
elif git show-ref --verify --quiet "refs/remotes/upstream/$BASELINE_BRANCH"; then
  log "Origin/$BRANCH not found; creating $BRANCH from upstream/$BASELINE_BRANCH"
  git checkout -q -B "$BRANCH" "upstream/$BASELINE_BRANCH"
else
  log "WARN: neither origin/$BRANCH nor upstream/$BASELINE_BRANCH exist; creating empty $BRANCH"
  git checkout -q -B "$BRANCH"
fi

# Rebase branch onto upstream baseline (policy 2)
if git show-ref --verify --quiet "refs/remotes/upstream/$BASELINE_BRANCH"; then
  log "Rebasing $BRANCH onto upstream/$BASELINE_BRANCH"
  if ! git rebase "upstream/$BASELINE_BRANCH"; then
    log "WARN: rebase failed; aborting rebase (manual conflict resolution needed)"
    git rebase --abort || true
    exit 0
  fi
else
  log "WARN: upstream baseline branch not found: $BASELINE_BRANCH (skipping rebase)"
fi

# Push rewritten/updated branch
log "Pushing $BRANCH to origin (force-with-lease)"
git push --force-with-lease origin "$BRANCH" || true

# If the repo uses the "workspace/" layout (as in slimelab-ai/openclaw-workspace),
# ensure the workspace root files OpenClaw reads are present as symlinks.
# This makes ~/AGENTS.md effectively equal to repo workspace/AGENTS.md.
if [[ -d workspace ]]; then
  log "Ensuring root workspace files are symlinks -> workspace/*"

  for f in AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md HEARTBEAT.md BOOTSTRAP.md; do
    if [[ -f "workspace/$f" ]]; then
      # If a real file exists at root, move it aside once.
      if [[ -e "$f" && ! -L "$f" ]]; then
        ts="$(date +%Y%m%d-%H%M%S)"
        mv -f "$f" "$f.legacy.$ts" || true
      fi
      ln -sfn "workspace/$f" "$f"
    fi
  done

  # Skills: prefer tracking under workspace/skills and symlink root skills -> workspace/skills
  if [[ -d workspace/skills ]]; then
    if [[ -e skills && ! -L skills ]]; then
      ts="$(date +%Y%m%d-%H%M%S)"
      mv -f skills "skills.legacy.$ts" || true
    fi
    ln -sfn workspace/skills skills
  fi
fi

log "OK: live workspace is git-backed at $LIVE_WORKSPACE"

git remote -v | sed 's/^/[github-workspace] /'

git rev-parse --abbrev-ref HEAD | sed 's/^/[github-workspace] branch: /'

git rev-parse HEAD | sed 's/^/[github-workspace] head: /'

popd >/dev/null
