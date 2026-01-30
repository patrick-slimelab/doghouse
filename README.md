# doghouse

A locked-down Docker Compose setup for running a "Scoob" Moltbot/Clawdbot instance (a separate assistant) on the Patrick host.

## Goals
- Scoob runs in a container ("sudo" inside container is fine)
- No access to Patrick host secrets
- No Docker socket mount, no privileged container
- Can reach the host ooba OpenAI-compatible API at `http://host.docker.internal:5000`

## Quick start
1. Copy `.env.example` to `.env` and fill in values.
2. Start:
   ```bash
   docker compose up -d --build
   ```
3. Logs:
   ```bash
   docker compose logs -f
   ```

## Notes
- This container intentionally does **not** mount `/var/run/docker.sock`.
- This container adds `host.docker.internal` via the Docker "host-gateway" feature.

## Permissions & Sudo
The `scoob` user inside the container has passwordless sudo (`scoob ALL=(ALL) NOPASSWD:ALL`).

To allow Moltbot to run `sudo` commands without asking for approval:
- Set `agents.defaults.elevatedDefault = "full"` in config.
- This is enforced by `entrypoint.sh` on boot.
