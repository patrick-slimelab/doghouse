#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a per-dog PRIVATE workspace repo and sync it into the live OpenClaw workspace.
#
# IMPORTANT: LIVE_WORKSPACE (e.g. /home/scoob) is NOT a git repo.
# We keep the git checkout separately (REPO_DIR), and symlink root workspace files
# (AGENTS.md, SOUL.md, etc.) from REPO_DIR/workspace/* into LIVE_WORKSPACE.
#
# Policy: rebase-based (clean stack of dog commits on top of a model baseline)

OWNER="${DOGHOUSE_GITHUB_OWNER:-cyberscoob}"
REPO_NAME="${DOGHOUSE_WORKSPACE_REPO:-openclaw-workspace}"
UPSTREAM_URL="${DOGHOUSE_WORKSPACE_UPSTREAM_URL:-https://github.com/slimelab-ai/openclaw-workspace.git}"

# The dog's working branch in the private repo.
BRANCH="${DOGHOUSE_WORKSPACE_BRANCH:-main}"

# The baseline branch to rebase onto, in the slimelab upstream repo.
BASELINE_BRANCH="${DOGHOUSE_WORKSPACE_BASELINE_BRANCH:-main}"

LIVE_WORKSPACE="${DOGHOUSE_WORKSPACE:?DOGHOUSE_WORKSPACE must be set}"
REPO_DIR="${DOGHOUSE_WORKSPACE_REPO_DIR:-/home/scoob/.openclaw/workspace-repo}"

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

# Ensure gh configures git credential helper (so `git push` works)
(gh auth setup-git -h "${GH_HOST:-github.com}" >/dev/null 2>&1) || true

# Clone/update local repo checkout
mkdir -p "$(dirname "$REPO_DIR")"
if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "Cloning private workspace repo -> $REPO_DIR"
  git clone --quiet "https://github.com/$OWNER/$REPO_NAME.git" "$REPO_DIR"
fi

pushd "$REPO_DIR" >/dev/null

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

# Backup current head (just in case)
current_head="$(git rev-parse HEAD 2>/dev/null || true)"
if [[ -n "$current_head" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  git branch "backup/legacy-$ts" "$current_head" >/dev/null 2>&1 || true
fi

# Force the working branch to exist and be checked out.
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
git push --force-with-lease origin "$BRANCH" >/dev/null 2>&1 || true

# Symlink workspace files into LIVE_WORKSPACE
mkdir -p "$LIVE_WORKSPACE"

if [[ -d workspace ]]; then
  log "Ensuring LIVE_WORKSPACE root files are symlinks -> $REPO_DIR/workspace/*"

  for f in AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md HEARTBEAT.md BOOTSTRAP.md; do
    if [[ -f "workspace/$f" ]]; then
      if [[ -e "$LIVE_WORKSPACE/$f" && ! -L "$LIVE_WORKSPACE/$f" ]]; then
        ts="$(date +%Y%m%d-%H%M%S)"
        mv -f "$LIVE_WORKSPACE/$f" "$LIVE_WORKSPACE/$f.legacy.$ts" || true
      fi
      ln -sfn "$REPO_DIR/workspace/$f" "$LIVE_WORKSPACE/$f"
    fi
  done

  # skills
  if [[ -d workspace/skills ]]; then
    if [[ -e "$LIVE_WORKSPACE/skills" && ! -L "$LIVE_WORKSPACE/skills" ]]; then
      ts="$(date +%Y%m%d-%H%M%S)"
      mv -f "$LIVE_WORKSPACE/skills" "$LIVE_WORKSPACE/skills.legacy.$ts" || true
    fi
    ln -sfn "$REPO_DIR/workspace/skills" "$LIVE_WORKSPACE/skills"
  fi
else
  log "WARN: repo has no ./workspace directory; cannot link root workspace files"
fi

log "OK: repo checkout at $REPO_DIR; live workspace at $LIVE_WORKSPACE"

popd >/dev/null
