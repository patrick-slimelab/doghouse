---
name: onion-browser
description: "Browse or fetch Tor .onion sites from an OpenClaw instance using a SOCKS5 proxy (Tor). Use when the user asks to open a .onion link, fetch a hidden-service page, or check availability/content of onion URLs."
---

# Onion Browser (Tor)

This skill assumes you have a Tor SOCKS5 proxy reachable.

- Default proxy (override via env): `TOR_SOCKS5_HOST=host.docker.internal`, `TOR_SOCKS5_PORT=9050`
- URL must be `http(s)://...onion/...`

## Quick checks

```bash
# confirm proxy env
echo "$TOR_SOCKS5_HOST:$TOR_SOCKS5_PORT"

# fetch a page (prints first 120 lines)
onion-fetch 'http://exampleonion.onion/' | sed -n '1,120p'
```

## Notes

- If fetch fails, verify Tor is running and that the SOCKS port is reachable from the container.
- Prefer saving output to a file for large pages:

```bash
onion-fetch 'http://exampleonion.onion/' > page.html
```
