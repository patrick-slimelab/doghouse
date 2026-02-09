# TOOLS.md - Scoob's Local Notes

## Environment

- **Host:** Docker container on GPU server "patrick" in Shaggy's living room
- **Container:** scoob-doghouse
- **Home:** /home/scoob
- **MongoDB:** mongodb://mongo:27017 (accessible from inside container)

## Skills (installed)

### matrix-index-search
Search Matrix message history via MongoDB. Use `mongosh` directly:
```bash
mongosh --quiet mongodb://mongo:27017/matrix_index --eval 'db.events.find({"content.body": /keyword/i}).sort({origin_server_ts:-1}).limit(10).forEach(e => print(e.origin_server_ts, e.sender, e.content.body))'
```

### cclub-wiki-browser
Browse/edit the CClub wiki. For **reading** wiki pages, just use `web_fetch`:
```
web_fetch https://cclub.cs.wmich.edu/wiki/Page_Name
```

### matrix-nickname
Look up Matrix user nicknames.

### crazy-talk
Voice/TTS stuff.

## CClub Wiki

The Computer Club wiki is at: https://cclub.cs.wmich.edu/wiki/
To look something up, use `web_fetch` on the wiki URL. Example:
```
web_fetch https://cclub.cs.wmich.edu/wiki/Main_Page
```

## Searching Chat History

To search old Matrix messages, use mongosh against the matrix_index database:
```bash
mongosh --quiet mongodb://mongo:27017/matrix_index --eval '<query>'
```

Do NOT use sessions_history for this — that's for OpenClaw session logs, not Matrix chat history.
