Put secret files here (NOT committed).

Expected files (examples):
- `discord_bot_token` (Discord bot token)
- `matrix_homeserver` (e.g. `https://matrix.example.org`)
- `matrix_user_id` (e.g. `@scoob:example.org`)
- `matrix_password` (Matrix account password)
- `gateway_token` (Moltbot Gateway auth token; generate a long random string)

Create with:
```bash
mkdir -p secrets
chmod 700 secrets
printf "%s" "<token>" > secrets/discord_bot_token
chmod 600 secrets/discord_bot_token
```
