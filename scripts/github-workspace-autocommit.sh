#!/usr/bin/env bash
set -euo pipefail

# Periodically commit/push changes in the LIVE workspace repo.
#
# This repo is the dog's private workspace repo (LIVE_WORKSPACE is a git checkout).
# We commit a conservative set of paths by default (identity + tools + skills),
# so the dog can't accidentally rewrite the whole prompt stack without you noticing.

OWNER="${DOGHOUSE_GITHUB_OWNER:-cyberscoob}"
REPO_NAME="${DOGHOUSE_WORKSPACE_REPO:-openclaw-workspace}"
BRANCH="${DOGHOUSE_WORKSPACE_BRANCH:-main}"

LIVE_WORKSPACE="${DOGHOUSE_WORKSPACE:?DOGHOUSE_WORKSPACE must be set}"
INTERVAL_SECONDS="${DOGHOUSE_WORKSPACE_AUTOCOMMIT_SECONDS:-300}"

# Space-separated pathspecs relative to workspace root.
# Override if you want to track more/less.
PATHS_RAW="${DOGHOUSE_WORKSPACE_AUTOCOMMIT_PATHS:-IDENTITY.md TOOLS.md skills}"

log() { echo "[github-workspace-autocommit] $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
need git

if [[ ! -d "$LIVE_WORKSPACE/.git" ]]; then
  log "Live workspace is not a git repo at $LIVE_WORKSPACE; skipping autocommit"
  exit 0
fi

# Convert PATHS_RAW into an array safely
read -r -a PATHS <<< "$PATHS_RAW"

while true; do
  sleep "$INTERVAL_SECONDS"

  pushd "$LIVE_WORKSPACE" >/dev/null || continue

  git checkout -q "$BRANCH" 2>/dev/null || true

  # See if any tracked paths changed
  if [[ -z "$(git status --porcelain -- "${PATHS[@]}" 2>/dev/null || true)" ]]; then
    popd >/dev/null
    continue
  fi

  git add -A -- "${PATHS[@]}" || true

  msg="workspace: autosync $(date -Is)"
  git commit -m "$msg" >/dev/null 2>&1 || true

  # Pull/rebase then push (best-effort)
  git pull --rebase --autostash origin "$BRANCH" >/dev/null 2>&1 || true
  git push origin "$BRANCH" >/dev/null 2>&1 || true

  popd >/dev/null
  log "Committed + pushed changes to $OWNER/$REPO_NAME ($BRANCH)"
done
