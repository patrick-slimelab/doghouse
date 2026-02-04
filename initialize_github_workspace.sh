#!/usr/bin/env bash
set -euo pipefail

# initialize_github_workspace.sh
#
# Purpose:
#   Create a PRIVATE repo under the cyberscoob GitHub account named "openclaw-workspace"
#   (private repos cannot be forks), seed it from slimelab-ai/openclaw-workspace,
#   and configure remotes so slimelab stays as "upstream".
#
# Runs from the HOST and execs into the running doghouse container.
#
# Requirements:
#   - docker available on host
#   - doghouse container running (default name: doghouse)
#   - inside container: git + gh installed
#   - inside container: gh authenticated as cyberscoob (we preauth via GH_TOKEN on startup)
#
# Usage:
#   ./initialize_github_workspace.sh
#   CONTAINER=doghouse ./initialize_github_workspace.sh
#   GITHUB_OWNER=cyberscoob REPO_NAME=openclaw-workspace ./initialize_github_workspace.sh
#

CONTAINER="${CONTAINER:-doghouse}"
GITHUB_OWNER="${GITHUB_OWNER:-cyberscoob}"
REPO_NAME="${REPO_NAME:-openclaw-workspace}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/slimelab-ai/openclaw-workspace.git}"

set -x

docker exec -i "$CONTAINER" bash -lc '
  set -euo pipefail

  OWNER="'"$GITHUB_OWNER"'"
  NAME="'"$REPO_NAME"'"
  UPSTREAM="'"$UPSTREAM_URL"'"

  if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh not installed inside container" >&2
    exit 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git not installed inside container" >&2
    exit 1
  fi

  # Ensure gh is authenticated (we expect entrypoint preauth, but verify)
  if ! gh auth status -h "${GH_HOST:-github.com}" >/dev/null 2>&1; then
    echo "ERROR: gh is not authenticated inside the container. Ensure GH_TOKEN is set and entrypoint preauth is enabled." >&2
    exit 1
  fi

  workdir="/home/scoob/src"
  mkdir -p "$workdir"
  cd "$workdir"

  # If repo already exists on GitHub, we will just ensure local remotes are correct.
  if gh repo view "$OWNER/$NAME" >/dev/null 2>&1; then
    echo "Repo $OWNER/$NAME already exists on GitHub. Will only ensure local clone/remotes." >&2
  else
    # Clone upstream and create a new private repo (NOT a fork) under $OWNER
    rm -rf "$NAME"
    git clone "$UPSTREAM" "$NAME"
    cd "$NAME"

    # Create and push private repo from this directory
    gh repo create "$OWNER/$NAME" --private --source=. --remote=origin --push

    # Rewire remotes: upstream = slimelab, origin = private repo
    git remote rename origin upstream
    git remote add origin "git@github.com:$OWNER/$NAME.git"

    git push -u origin --all
    git push origin --tags

    echo "Initialized $OWNER/$NAME (private) from $UPSTREAM" >&2
    exit 0
  fi

  # Existing repo path? ensure we have a clone
  if [ ! -d "$NAME/.git" ]; then
    rm -rf "$NAME"
    git clone "git@github.com:$OWNER/$NAME.git" "$NAME"
  fi

  cd "$NAME"

  # Ensure upstream remote exists/points correctly
  if git remote get-url upstream >/dev/null 2>&1; then
    git remote set-url upstream "$UPSTREAM"
  else
    git remote add upstream "$UPSTREAM"
  fi

  # Ensure origin points to private repo
  git remote set-url origin "git@github.com:$OWNER/$NAME.git"

  echo "OK: remotes configured" >&2
  git remote -v >&2
'
