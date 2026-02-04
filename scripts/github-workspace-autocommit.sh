#!/usr/bin/env bash
set -euo pipefail

# Periodically mirror LIVE workspace -> repo ./workspace and commit/push changes.
#
# Intended to run in background inside the container as the dog user.

OWNER="${DOGHOUSE_GITHUB_OWNER:-cyberscoob}"
REPO_NAME="${DOGHOUSE_WORKSPACE_REPO:-openclaw-workspace}"
BRANCH="${DOGHOUSE_WORKSPACE_BRANCH:-main}"

LIVE_WORKSPACE="${DOGHOUSE_WORKSPACE:?DOGHOUSE_WORKSPACE must be set}"
REPO_DIR="${DOGHOUSE_WORKSPACE_REPO_DIR:-/home/scoob/.openclaw/workspace-repo}"

INTERVAL_SECONDS="${DOGHOUSE_WORKSPACE_AUTOCOMMIT_SECONDS:-300}"

log() { echo "[github-workspace-autocommit] $*"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
need git
need rsync

if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "Repo not present at $REPO_DIR; skipping autocommit"
  exit 0
fi

while true; do
  sleep "$INTERVAL_SECONDS"

  pushd "$REPO_DIR" >/dev/null || continue

  # Only operate if ./workspace exists
  if [[ ! -d workspace ]]; then
    popd >/dev/null
    continue
  fi

  # Ensure branch checked out
  git checkout -q "$BRANCH" 2>/dev/null || true

  # Mirror live workspace into repo workspace (exclude memory)
  rsync -a --delete --exclude 'memory/' --exclude 'MEMORY.md' "$LIVE_WORKSPACE/" "workspace/" || true

  # If no changes under workspace/, do nothing
  if [[ -z "$(git status --porcelain -- workspace)" ]]; then
    popd >/dev/null
    continue
  fi

  git add -A workspace

  msg="workspace: autosync $(date -Is)"
  git commit -m "$msg" >/dev/null 2>&1 || true

  # Pull/rebase then push (best-effort)
  git pull --rebase --autostash origin "$BRANCH" >/dev/null 2>&1 || true
  git push origin "$BRANCH" >/dev/null 2>&1 || true

  popd >/dev/null
  log "Committed + pushed changes to $OWNER/$REPO_NAME ($BRANCH)"
done
