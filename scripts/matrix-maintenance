#!/bin/bash
set -euo pipefail

ENV_FILE="/home/scoob/matrix-indexer/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

MONGODB_URI="${MONGODB_URI:-mongodb://mongo:27017}"
MONGODB_DB="${MONGODB_DB:-matrix_index}"

STALE_SECONDS="${MATRIX_BACKFILL_STALE_SECONDS:-900}"          # 15m
ROOM_CACHE_INTERVAL_SECONDS="${MATRIX_ROOM_CACHE_INTERVAL_SECONDS:-600}" # 10m

last_room_cache=0

echo "[matrix-maintenance] starting (db=$MONGODB_URI/$MONGODB_DB stale=${STALE_SECONDS}s cacheEvery=${ROOM_CACHE_INTERVAL_SECONDS}s)"

while true; do
  now=$(date +%s)

  # 1) Release stale claimed backfill jobs
  mongosh "$MONGODB_URI/$MONGODB_DB" --quiet --eval "
    const cutoff = new Date(Date.now() - (${STALE_SECONDS} * 1000));
    const q = { done: false, claimed: true, updated_at: { \$lt: cutoff } };
    const r = db.room_backfill.updateMany(q, { \$set: { claimed: false, updated_at: new Date() } });
    if (r.modifiedCount > 0) {
      print('[matrix-maintenance] released stale claims: ' + r.modifiedCount);
    }
  " || true

  # 2) Cache room names/aliases incrementally
  if (( now - last_room_cache >= ROOM_CACHE_INTERVAL_SECONDS )); then
    last_room_cache=$now
    mongosh "$MONGODB_URI/$MONGODB_DB" --quiet --eval "
      db.meta ||= db.getCollection('meta');
      db.room_info ||= db.getCollection('room_info');

      const metaId = 'room_cache_last_ts';
      const meta = db.meta.findOne({ _id: metaId });
      const lastTs = meta && meta.value ? Number(meta.value) : 0;

      const types = ['m.room.name','m.room.canonical_alias','m.room.topic'];
      const cursor = db.events.find(
        { type: { \$in: types }, origin_server_ts: { \$gt: lastTs } },
        { room_id: 1, type: 1, origin_server_ts: 1, content: 1 }
      ).sort({ origin_server_ts: 1 });

      let maxTs = lastTs;
      let n = 0;

      while (cursor.hasNext()) {
        const ev = cursor.next();
        n++;
        const ts = Number(ev.origin_server_ts || 0);
        if (ts > maxTs) maxTs = ts;

        const update = { room_id: ev.room_id, updated_at: new Date(), last_event_ts: ts };

        if (ev.type === 'm.room.name' && ev.content && typeof ev.content.name === 'string') {
          update.name = ev.content.name;
        }
        if (ev.type === 'm.room.canonical_alias' && ev.content && typeof ev.content.alias === 'string') {
          update.canonical_alias = ev.content.alias;
        }
        if (ev.type === 'm.room.topic' && ev.content && typeof ev.content.topic === 'string') {
          update.topic = ev.content.topic;
        }

        db.room_info.updateOne(
          { room_id: ev.room_id },
          { \$set: update },
          { upsert: true }
        );
      }

      if (n > 0 && maxTs > lastTs) {
        db.meta.updateOne({ _id: metaId }, { \$set: { value: maxTs, updated_at: new Date() } }, { upsert: true });
        print('[matrix-maintenance] room cache updated: events=' + n + ' lastTs=' + maxTs);
      } else {
        print('[matrix-maintenance] room cache: no new events');
      }
    " || true
  fi

  sleep 60
done
