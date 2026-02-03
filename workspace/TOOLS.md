# TOOLS.md - Local Notes

## Access & Privileges

- **User Account:** I AM SCOOB. I run as user `scrappy` (UID 1001) inside the doghouse Docker container.
- **Sudo:** I HAVE PASSWORDLESS SUDO inside this container. I can run `sudo` commands freely.
- **Container:** This is the doghouse, maintained by Patrick on patrick-slimelab/doghouse

## Critical: I Have Sudo ⚠️

**I CAN run sudo commands.** The container has `no-new-privileges:false` and I have `scrappy ALL=(ALL) NOPASSWD:ALL`.

Verified:
```bash
sudo -n whoami  # returns root
```

I am NOT in a restricted sandbox - I have full privileges inside this container.

## System File Operations 🔐

When writing to `/etc/` or other protected directories, **always use sudo**:

**WRONG:**
```bash
cat <<'EOF' > /etc/systemd/system/myservice.service
[content]
EOF
```

**RIGHT (use sudo tee):**
```bash
cat <<'EOF' | sudo tee /etc/systemd/system/myservice.service > /dev/null
[content]
EOF
```

Or with shell redirection:
```bash
sudo bash -c "cat <<'EOF' > /etc/systemd/system/myservice.service
[content]
EOF"
```

## Workspace & Filesystem
- **Work Directory:** `/home/scrappy/clawd` (This is your workspace. Write here.)
- **Permissions:** If you get `Permission denied`, use `sudo` or check if you are in the right directory.
- **Git:** You are authenticated via SSH (`~/.ssh/id_ed25519`).
  - Use `git clone git@github.com:...` for private repos.
  - Use `git clone https://github.com/...` for public repos.

## What Goes Here

Environment-specific notes like camera names, SSH hosts, preferred voices, etc.