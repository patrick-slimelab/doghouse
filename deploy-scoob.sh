#!/usr/bin/env bash
set -euo pipefail

# deploy-scoob.sh — Run as patrick to deploy/redeploy Scoob's doghouse.
# No sudo required.

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SELF_DIR"

ACTION="${1:-up}"

log() { echo -e "\033[1;36m[deploy]\033[0m $*"; }

case "$ACTION" in
  up|deploy|start)
    log "Pulling latest doghouse repo..."
    git pull --ff-only 2>/dev/null || true

    log "Building + starting containers..."
    MOLTBOT_CACHE_BUST="$(date +%s)" docker compose up -d --build

    log "Waiting for containers..."
    sleep 5
    docker compose ps
    log "Done. Tail logs with: docker compose -f $SELF_DIR/docker-compose.yml logs -f doghouse"
    ;;

  down|stop)
    log "Stopping containers..."
    docker compose down
    log "Stopped."
    ;;

  restart)
    log "Restarting doghouse container..."
    docker compose restart doghouse
    log "Restarted."
    ;;

  rebuild)
    log "Full rebuild (down + build + up)..."
    docker compose down
    MOLTBOT_CACHE_BUST="$(date +%s)" docker compose up -d --build
    sleep 5
    docker compose ps
    log "Done."
    ;;

  logs)
    docker compose logs -f --tail=200 doghouse
    ;;

  status)
    docker compose ps
    ;;

  *)
    echo "Usage: $0 {up|down|restart|rebuild|logs|status}"
    exit 1
    ;;
esac
