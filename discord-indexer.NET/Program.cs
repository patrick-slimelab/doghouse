using System.Net.Http.Headers;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using MongoDB.Bson;
using MongoDB.Driver;

namespace DiscordIndexer;

public class Program
{
    private static readonly HttpClient Http = new();

    private static IMongoCollection<BsonDocument>? _messages;
    private static IMongoCollection<BsonDocument>? _backfill;

    private static int _backfillPageSize = 100; // Discord max
    private static int _backfillWorkers = 2;

    public static async Task Main(string[] args)
    {
        Console.WriteLine("Starting Discord Indexer (.NET)");

        var token = GetEnv("DISCORD_BOT_TOKEN");
        var apiBase = GetEnv("DISCORD_API_BASE", "https://discord.com/api/v10").TrimEnd(/);
        var gatewayUrl = GetEnv("DISCORD_GATEWAY_URL", "wss://gateway.discord.gg/?v=10&encoding=json");
        var guildIdsCsv = GetEnv("DISCORD_GUILD_IDS", "");
        var intents = int.Parse(GetEnv("DISCORD_INTENTS", "513")); // GUILDS + GUILD_MESSAGES

        var mongoUri = GetEnv("MONGODB_URI", "mongodb://localhost:27017");
        var mongoDbName = GetEnv("MONGODB_DB", "discord_index");

        _backfillPageSize = int.Parse(GetEnv("INDEXER_BACKFILL_PAGE_SIZE", _backfillPageSize.ToString()));
        _backfillWorkers = int.Parse(GetEnv("INDEXER_BACKFILL_WORKERS", _backfillWorkers.ToString()));

        if (_backfillPageSize is < 1 or > 100) _backfillPageSize = 100;

        // Mongo
        Console.WriteLine($"Connecting to MongoDB: {mongoUri}");
        var client = new MongoClient(mongoUri);
        var db = client.GetDatabase(mongoDbName);
        _messages = db.GetCollection<BsonDocument>("messages");
        _backfill = db.GetCollection<BsonDocument>("channel_backfill");
        await EnsureIndexes();
        Console.WriteLine("MongoDB indexes ensured.");

        // HTTP auth
        Http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bot", token);

        // Seed channels for backfill
        var guildIds = guildIdsCsv
            .Split(,, StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Distinct()
            .ToArray();

        if (guildIds.Length == 0)
        {
            Console.WriteLine("WARN: DISCORD_GUILD_IDS not set; cannot enumerate channels for backfill.");
            Console.WriteLine("Set DISCORD_GUILD_IDS=comma,separated,guildIds to enable history backfill.");
        }
        else
        {
            foreach (var gid in guildIds)
            {
                await SeedGuildChannels(apiBase, gid);
            }

            Console.WriteLine($"Starting backfill workers: {_backfillWorkers} (pageSize={_backfillPageSize})");
            for (var i = 0; i < _backfillWorkers; i++)
            {
                _ = Task.Run(() => BackfillWorkerLoop(apiBase));
            }
        }

        // Live gateway ingestion
        Console.WriteLine("Starting Discord gateway live ingestion...");
        while (true)
        {
            try
            {
                await RunGatewayLoop(gatewayUrl, token, intents);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Gateway loop error: {ex.Message}");
            }

            await Task.Delay(5000);
        }
    }

    private static async Task EnsureIndexes()
    {
        if (_messages == null || _backfill == null) return;

        await _messages.Indexes.CreateOneAsync(new CreateIndexModel<BsonDocument>(
            Builders<BsonDocument>.IndexKeys.Ascending("message_id"),
            new CreateIndexOptions { Unique = true }));

        await _messages.Indexes.CreateOneAsync(new CreateIndexModel<BsonDocument>(
            Builders<BsonDocument>.IndexKeys.Ascending("channel_id").Descending("timestamp_ms")));

        await _backfill.Indexes.CreateOneAsync(new CreateIndexModel<BsonDocument>(
            Builders<BsonDocument>.IndexKeys.Ascending("channel_id"),
            new CreateIndexOptions { Unique = true }));

        await _backfill.Indexes.CreateOneAsync(new CreateIndexModel<BsonDocument>(
            Builders<BsonDocument>.IndexKeys.Ascending("done").Ascending("updated_at")));
    }

    private static async Task SeedGuildChannels(string apiBase, string guildId)
    {
        if (_backfill == null) return;

        Console.WriteLine($"Fetching channels for guild {guildId}...");
        var url = $"{apiBase}/guilds/{guildId}/channels";
        var resp = await Http.GetAsync(url);
        if (!resp.IsSuccessStatusCode)
        {
            Console.WriteLine($"WARN: Failed to list channels for guild {guildId}: {(int)resp.StatusCode} {resp.ReasonPhrase}");
            return;
        }

        var json = await resp.Content.ReadAsStringAsync();
        var arr = JsonDocument.Parse(json).RootElement;
        if (arr.ValueKind != JsonValueKind.Array) return;

        foreach (var ch in arr.EnumerateArray())
        {
            var type = ch.GetProperty("type").GetInt32();
            // 0 = GUILD_TEXT, 5 = GUILD_ANNOUNCEMENT
            if (type != 0 && type != 5) continue;

            var channelId = ch.GetProperty("id").GetString();
            if (string.IsNullOrEmpty(channelId)) continue;

            await SeedBackfillChannel(channelId!, guildId);
        }
    }

    private static async Task SeedBackfillChannel(string channelId, string guildId)
    {
        if (_backfill == null) return;

        var filter = Builders<BsonDocument>.Filter.Eq("channel_id", channelId);
        var existing = await _backfill.Find(filter).FirstOrDefaultAsync();
        if (existing != null) return;

        var doc = new BsonDocument
        {
            { "channel_id", channelId },
            { "guild_id", guildId },
            { "cursor_before", BsonNull.Value },
            { "done", false },
            { "claimed", false },
            { "created_at", DateTime.UtcNow },
            { "updated_at", DateTime.UtcNow },
            { "error_count", 0 },
        };

        try
        {
            await _backfill.InsertOneAsync(doc);
            Console.WriteLine($"Seeded backfill for channel {channelId}");
        }
        catch
        {
            // ignore races
        }
    }

    private static async Task BackfillWorkerLoop(string apiBase)
    {
        if (_backfill == null) return;

        while (true)
        {
            try
            {
                var claim = await ClaimNextChannel();
                if (claim == null)
                {
                    await Task.Delay(2000);
                    continue;
                }

                var channelId = claim["channel_id"].AsString;
                var cursor = claim.Contains("cursor_before") && !claim["cursor_before"].IsBsonNull
                    ? claim["cursor_before"].AsString
                    : null;

                var (newCursor, done, count) = await BackfillOnePage(apiBase, channelId, cursor);

                await UpdateChannelState(channelId, newCursor, done, 0);

                await Task.Delay(350);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Backfill worker error: {ex.Message}");
                await Task.Delay(2000);
            }
        }
    }

    private static async Task<BsonDocument?> ClaimNextChannel()
    {
        if (_backfill == null) return null;

        var filter = Builders<BsonDocument>.Filter.And(
            Builders<BsonDocument>.Filter.Eq("done", false),
            Builders<BsonDocument>.Filter.Ne("claimed", true)
        );

        var update = Builders<BsonDocument>.Update
            .Set("claimed", true)
            .Set("updated_at", DateTime.UtcNow);

        return await _backfill.FindOneAndUpdateAsync(
            filter,
            update,
            new FindOneAndUpdateOptions<BsonDocument>
            {
                ReturnDocument = ReturnDocument.After,
                Sort = Builders<BsonDocument>.Sort.Ascending("updated_at")
            });
    }

    private static async Task UpdateChannelState(string channelId, string? newCursor, bool done, int errorDelta)
    {
        if (_backfill == null) return;

        var filter = Builders<BsonDocument>.Filter.Eq("channel_id", channelId);

        var upd = Builders<BsonDocument>.Update
            .Set("cursor_before", newCursor == null ? BsonNull.Value : newCursor)
            .Set("done", done)
            .Set("claimed", false)
            .Set("updated_at", DateTime.UtcNow);

        if (errorDelta > 0)
            upd = upd.Inc("error_count", errorDelta);

        await _backfill.UpdateOneAsync(filter, upd);
    }

    private static async Task<(string? newCursor, bool done, int count)> BackfillOnePage(string apiBase, string channelId, string? before)
    {
        var url = $"{apiBase}/channels/{channelId}/messages?limit={_backfillPageSize}";
        if (!string.IsNullOrEmpty(before))
            url += $"&before={before}";

        var resp = await Http.GetAsync(url);
        if (!resp.IsSuccessStatusCode)
        {
            Console.WriteLine($"WARN: Backfill fetch failed for channel {channelId}: {(int)resp.StatusCode} {resp.ReasonPhrase}");
            return (before, false, 0);
        }

        var json = await resp.Content.ReadAsStringAsync();
        var root = JsonDocument.Parse(json).RootElement;
        if (root.ValueKind != JsonValueKind.Array)
            return (before, false, 0);

        var msgs = root.EnumerateArray().ToList();
        if (msgs.Count == 0)
        {
            Console.WriteLine($"Backfill done for channel {channelId}");
            return (before, true, 0);
        }

        var oldest = msgs.Last().GetProperty("id").GetString();

        foreach (var m in msgs)
        {
            await InsertMessage(m, source: "backfill");
        }

        Console.WriteLine($"Backfilled {msgs.Count} messages from channel {channelId}");
        return (oldest, false, msgs.Count);
    }

    private static async Task InsertMessage(JsonElement msg, string source)
    {
        if (_messages == null) return;

        var id = msg.GetProperty("id").GetString() ?? "";
        var channelId = msg.TryGetProperty("channel_id", out var cid) ? cid.GetString() : null;
        var timestamp = msg.TryGetProperty("timestamp", out var ts) ? ts.GetString() : null;
        var guildId = msg.TryGetProperty("guild_id", out var gid) ? gid.GetString() : null;

        long tsMs = 0;
        if (!string.IsNullOrEmpty(timestamp) && DateTimeOffset.TryParse(timestamp, out var dto))
            tsMs = dto.ToUnixTimeMilliseconds();

        var doc = new BsonDocument
        {
            { "message_id", id },
            { "channel_id", channelId ?? BsonNull.Value },
            { "guild_id", guildId ?? BsonNull.Value },
            { "timestamp", timestamp ?? BsonNull.Value },
            { "timestamp_ms", tsMs },
            { "source", source },
            { "raw", BsonDocument.Parse(msg.GetRawText()) },
            { "ingested_at", DateTime.UtcNow },
        };

        try
        {
            await _messages.InsertOneAsync(doc);
        }
        catch (MongoWriteException mwx) when (mwx.WriteError.Category == ServerErrorCategory.DuplicateKey)
        {
            // ignore duplicates
        }
    }

    private static async Task RunGatewayLoop(string gatewayUrl, string token, int intents)
    {
        using var ws = new ClientWebSocket();
        await ws.ConnectAsync(new Uri(gatewayUrl), CancellationToken.None);

        using var helloDoc = await ReceiveJson(ws);
        var interval = helloDoc.RootElement.GetProperty("d").GetProperty("heartbeat_interval").GetInt32();

        int? seq = null;

        using var cts = new CancellationTokenSource();

        var hbTask = Task.Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                await Task.Delay(interval);
                var payload = new { op = 1, d = seq };
                await SendJson(ws, payload);
            }
        });

        var identify = new
        {
            op = 2,
            d = new
            {
                token,
                intents,
                properties = new { os = "linux", browser = "discord-indexer", device = "discord-indexer" }
            }
        };
        await SendJson(ws, identify);

        while (ws.State == WebSocketState.Open)
        {
            using var msg = await ReceiveJson(ws);
            var root = msg.RootElement;

            if (root.TryGetProperty("s", out var sEl) && sEl.ValueKind != JsonValueKind.Null)
                seq = sEl.GetInt32();

            var op = root.GetProperty("op").GetInt32();
            if (op == 0)
            {
                var t = root.GetProperty("t").GetString();
                var d = root.GetProperty("d");

                if (t == "MESSAGE_CREATE")
                {
                    await InsertMessage(d, source: "live");
                }
            }
            else if (op == 7 || op == 9)
            {
                break;
            }
        }

        cts.Cancel();
        try { await hbTask; } catch { /* ignore */ }

        try { await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None); } catch { }
    }

    private static async Task<JsonDocument> ReceiveJson(ClientWebSocket ws)
    {
        var buffer = new byte[1 << 16];
        var sb = new StringBuilder();
        while (true)
        {
            var res = await ws.ReceiveAsync(buffer, CancellationToken.None);
            if (res.MessageType == WebSocketMessageType.Close)
                throw new Exception("Gateway closed");

            sb.Append(Encoding.UTF8.GetString(buffer, 0, res.Count));
            if (res.EndOfMessage) break;
        }
        return JsonDocument.Parse(sb.ToString());
    }

    private static Task SendJson(ClientWebSocket ws, object payload)
    {
        var json = JsonSerializer.Serialize(payload);
        var bytes = Encoding.UTF8.GetBytes(json);
        return ws.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
    }

    private static string GetEnv(string key, string? def = null)
    {
        var v = Environment.GetEnvironmentVariable(key);
        if (!string.IsNullOrEmpty(v)) return v;
        if (def != null) return def;
        throw new Exception($"Missing required env var: {key}");
    }
}
