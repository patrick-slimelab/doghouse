# secrets/

This folder is ignored by git (except this README).

## Required/expected files

- `github.env`      (env_file for docker compose)
- `gh_token`        (docker secret used inside container)
- `bot_canonical_name`  (single line: the bot's canonical name, e.g. `scoob` or `scrappy`)

`bot_canonical_name` is used to set stable Docker `container_name` values like:
- `<name>-doghouse`
- `<name>-doghouse-init`
- `<name>-doghouse-mongo`

This makes it easy to target the right containers from host scripts.
