-- 段階3の手直し: ポッドキャストの回を items から episodes へ分ける（2026-11-24）
-- 記事の仕組み（既読・コメント・paw_queue・item_tombstones・初回 20 件・既読 90 日で消す）から回を切り離す。
-- 番組の回は上限なしに全部持ち、フィードから消えた回も消さない。
-- ⚠️ 本番（--remote）へはヘスティアが中身を確かめてから流す。何度流しても同じ結果になる（2回目以降は掃除だけ）
--
-- 回の id は旧 items.id を引き継ぐ（iPhone の中のキュー・再生位置・ダウンロード・「見た」目印が回の id で持っているため）。
-- 重複は (feed_id, guid) で除く（guid は guid／id → url → 題名の順で作る・parse.ts）
CREATE TABLE IF NOT EXISTS episodes (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  feed_id        INTEGER NOT NULL REFERENCES feeds (id) ON DELETE CASCADE,
  guid           TEXT    NOT NULL,
  url            TEXT,                  -- 回のページ（無い配信もある）
  title          TEXT    NOT NULL,
  published_at   TEXT,
  fetched_at     TEXT    NOT NULL,
  sort_at        TEXT    NOT NULL,      -- 並びに使う時刻（items と同じ決め方）
  enclosure_url  TEXT    NOT NULL,      -- 音声。音声の無い回は入れない
  enclosure_type TEXT,
  duration_sec   INTEGER,
  UNIQUE (feed_id, guid)
);
-- 番組ごとの一覧（新しい順）と、全番組の新着（新しい順）
CREATE INDEX IF NOT EXISTS episodes_feed_sort ON episodes (feed_id, sort_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS episodes_sort ON episodes (sort_at DESC, id DESC);

-- 1. 番組の回（音声のあるもの）を id ごと写す。もうある回（2回目・取得で入った回）は触らない
INSERT OR IGNORE INTO episodes (id, feed_id, guid, url, title, published_at, fetched_at, sort_at, enclosure_url, enclosure_type, duration_sec)
SELECT i.id, i.feed_id, i.guid, i.url, i.title, i.published_at, i.fetched_at, i.sort_at, i.enclosure_url, i.enclosure_type, i.duration_sec
  FROM items i JOIN feeds f ON f.id = i.feed_id
 WHERE f.kind = 'podcast' AND i.enclosure_url IS NOT NULL;

-- 2. これから入る回の id を、items でこれまでに配った id より大きくする。
--    （上限 300 で消えた回の id を iPhone がまだ持っていても、新しい回と取り違えないように）
--    仮の行を items の連番の位置に入れて消す（AUTOINCREMENT の連番は消しても戻らない）
INSERT OR IGNORE INTO episodes (id, feed_id, guid, title, fetched_at, sort_at, enclosure_url)
SELECT s.seq, (SELECT MIN(id) FROM feeds), '__tayori_0006_seq__', '', '', '', ''
  FROM sqlite_sequence s
 WHERE s.name = 'items'
   AND s.seq > COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'episodes'), 0)
   AND (SELECT MIN(id) FROM feeds) IS NOT NULL;
DELETE FROM episodes WHERE guid = '__tayori_0006_seq__';

-- 3. items から番組の回を消す。コメントのある回だけは items に残す（記事一覧には kind で出ない）
DELETE FROM paw_queue
 WHERE item_id IN (SELECT i.id FROM items i JOIN feeds f ON f.id = i.feed_id WHERE f.kind = 'podcast' AND i.comment IS NULL);
DELETE FROM items
 WHERE comment IS NULL AND feed_id IN (SELECT id FROM feeds WHERE kind = 'podcast');
DELETE FROM item_tombstones WHERE feed_id IN (SELECT id FROM feeds WHERE kind = 'podcast');

-- 4. 番組は次の取得で条件なしに全文を取り直す（300 回より前の過去回を入れるため）
UPDATE feeds SET etag = NULL, last_modified = NULL WHERE kind = 'podcast';
