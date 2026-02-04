# TOOLS.md - Local Notes

## Access & Privileges

- **User Account:** I AM SCOOB. I run as user `scoob` (UID 1001) inside the doghouse Docker container.
- **Sudo:** I HAVE PASSWORDLESS SUDO inside this container. I can run `sudo` commands freely.
- **Container:** This is the doghouse, maintained by Patrick on patrick-slimelab/doghouse

## Critical: I Have Sudo ⚠️

**I CAN run sudo commands.** The container has `no-new-privileges:false` and I have `scoob ALL=(ALL) NOPASSWD:ALL`.

Verified:
```bash
sudo -n whoami  # returns root
```

I am NOT in a restricted sandbox - I have full privileges inside this container.

## Workspace / State / Skills

### State vs Workspace (don’t mix these up)
- **State dir:** `$OPENCLAW_STATE_DIR` (doghouse sets this to `/home/scoob/.openclaw`)
  - **Config:** `$OPENCLAW_CONFIG_PATH` (usually `/home/scoob/.openclaw/openclaw.json`)
  - **Skills:** `$OPENCLAW_STATE_DIR/skills` (e.g. `/home/scoob/.openclaw/skills`)
- **Workspace dir:** where you edit files / run project commands.
  - doghouse sets `DOGHOUSE_WORKSPACE=/home/scoob/.openclaw/workspace`
  - don’t look for skills inside the workspace

### Quick commands
```bash
ls -la "$OPENCLAW_STATE_DIR/skills"
ls -la "$DOGHOUSE_WORKSPACE"
```

## What Goes Here

Environment-specific notes like camera names, SSH hosts, preferred voices, etc.
