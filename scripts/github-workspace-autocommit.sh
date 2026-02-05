#!/usr/bin/env bash
set -euo pipefail

# Periodically commit/push changes to the dog's private workspace repo.
#
# NOTE: The live OpenClaw workspace directory is NOT the git repo. The git repo lives at REPO_DIR.
# We commit from REPO_DIR, typically only under workspace/ (prompt files + skills).

OWNER="${DOGHOUSE_GITHUB_OWNER:-cyberscoob}"
REPO_NAME="${DOGHOUSE_WORKSPACE_REPO:-openclaw-workspace}"
BRANCH="${DOGHOUSE_WORKSPACE_BRANCH:-main}"

REPO_DIR="${DOGHOUSE_WORKSPACE_REPO_DIR:-/home/scoob/.openclaw/workspace-repo}"
INTERVAL_SECONDS="${DOGHOUSE_WORKSPACE_AUTOCOMMIT_SECONDS:-300}"

# Space-separated pathspecs relative to REPO_DIR.
# Default: commit prompt templates + skills.
PATHS_RAW="${DOGHOUSE_WORKSPACE_AUTOCOMMIT_PATHS:-workspace}"

log() { echo "[github-workspace-autocommit] $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
need git

if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "Repo not present at $REPO_DIR; skipping autocommit"
  exit 0
fi

read -r -a PATHS <<< "$PATHS_RAW"

while true; do
  sleep "$INTERVAL_SECONDS"

  pushd "$REPO_DIR" >/dev/null || continue

  git checkout -q "$BRANCH" 2>/dev/null || true

  if [[ -z "$(git status --porcelain -- "${PATHS[@]}" 2>/dev/null || true)" ]]; then
    popd >/dev/null
    continue
  fi

  git add -A -- "${PATHS[@]}" || true
  msg="workspace: autosync $(date -Is)"
  git commit -m "$msg" >/dev/null 2>&1 || true

  git pull --rebase --autostash origin "$BRANCH" >/dev/null 2>&1 || true
  git push origin "$BRANCH" >/dev/null 2>&1 || true

  popd >/dev/null
  log "Committed + pushed changes to $OWNER/$REPO_NAME ($BRANCH)"
done
