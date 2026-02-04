#!/usr/bin/env bash
set -euo pipefail

# Deprecated: use ./deploy.sh
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy.sh" "$@"
