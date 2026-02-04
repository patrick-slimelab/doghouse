#!/usr/bin/env bash
set -euo pipefail

# Periodically commit/push memory repo changes.

OWNER="${DOGHOUSE_GITHUB_OWNER:-cyberscoob}"
REPO_NAME="${DOGHOUSE_MEMORY_REPO:-openclaw-memory}"
BRANCH="${DOGHOUSE_MEMORY_BRANCH:-main}"

MEM_REPO_DIR="${DOGHOUSE_MEMORY_REPO_DIR:-/home/scoob/.openclaw/memory-repo}"
INTERVAL_SECONDS="${DOGHOUSE_MEMORY_AUTOCOMMIT_SECONDS:-300}"

log() { echo "[github-memory-autocommit] $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
need git

if [[ ! -d "$MEM_REPO_DIR/.git" ]]; then
  log "Memory repo not present at $MEM_REPO_DIR; skipping autocommit"
  exit 0
fi

while true; do
  sleep "$INTERVAL_SECONDS"

  pushd "$MEM_REPO_DIR" >/dev/null || continue

  git checkout -q "$BRANCH" 2>/dev/null || true

  if [[ -z "$(git status --porcelain)" ]]; then
    popd >/dev/null
    continue
  fi

  git add -A
  msg="memory: autosync $(date -Is)"
  git commit -m "$msg" >/dev/null 2>&1 || true

  git pull --rebase --autostash origin "$BRANCH" >/dev/null 2>&1 || true
  git push origin "$BRANCH" >/dev/null 2>&1 || true

  popd >/dev/null
  log "Committed + pushed changes to $OWNER/$REPO_NAME ($BRANCH)"
done
