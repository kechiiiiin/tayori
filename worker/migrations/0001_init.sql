-- 便り（tayori）の初期スキーマ（設計: jinsei vault hestia/projects/RSSフィーダー設計.md）
-- 時刻はすべて ISO 8601（UTC・ミリ秒つき）の文字列

-- カテゴリ（フォルダ式・1つのサイトに1つ）。sort は 0 からの並び順
CREATE TABLE categories (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  name       TEXT    NOT NULL,
  sort       INTEGER NOT NULL DEFAULT 0,
  created_at TEXT    NOT NULL
);

-- 購読しているフィード。category_id が NULL なら「未分類」
CREATE TABLE feeds (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  category_id     INTEGER REFERENCES categories (id) ON DELETE SET NULL,
  title           TEXT    NOT NULL,
  site_url        TEXT,
  feed_url        TEXT    NOT NULL UNIQUE,
  etag            TEXT,
  last_modified   TEXT,
  last_fetched_at TEXT,
  last_error      TEXT,                     -- 最後の取得が失敗したときだけ入る（成功・304 で消す）
  rururu_paw      INTEGER NOT NULL DEFAULT 0, -- 段階2: rururu へ送るサイト
  created_at      TEXT    NOT NULL
);
CREATE INDEX feeds_category ON feeds (category_id);
CREATE INDEX feeds_stale ON feeds (last_fetched_at);

-- 記事。(feed_id, guid) で重複を除く。guid が無い記事は url（それも無ければ題名）を guid にする
-- sort_at = 並びに使う時刻（published_at が読めて未来でなければそれ、だめなら fetched_at）
CREATE TABLE items (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  feed_id            INTEGER NOT NULL REFERENCES feeds (id) ON DELETE CASCADE,
  guid               TEXT    NOT NULL,
  url                TEXT,
  title              TEXT    NOT NULL,
  published_at       TEXT,
  fetched_at         TEXT    NOT NULL,
  sort_at            TEXT    NOT NULL,
  read_at            TEXT,                  -- POST /api/items/:id/read でだけ入る。DELETE で NULL に戻る
  comment            TEXT,                  -- 自分だけのメモ。空にしたら NULL
  comment_updated_at TEXT,
  UNIQUE (feed_id, guid)
);
CREATE INDEX items_sort ON items (sort_at DESC, id DESC);
CREATE INDEX items_unread ON items (read_at, sort_at DESC);
CREATE INDEX items_feed ON items (feed_id, read_at);

-- 一度見た記事の guid の控え。初回の 21 件目以降と、90 日で消した記事が、次の取得で未読として戻らないように
CREATE TABLE item_tombstones (
  feed_id    INTEGER NOT NULL REFERENCES feeds (id) ON DELETE CASCADE,
  guid       TEXT    NOT NULL,
  created_at TEXT    NOT NULL,
  PRIMARY KEY (feed_id, guid)
);

-- 段階2（rururu への paw）で使う。段階1では作るだけ
CREATE TABLE paw_queue (
  item_id   INTEGER PRIMARY KEY REFERENCES items (id) ON DELETE CASCADE,
  queued_at TEXT NOT NULL,
  sent_at   TEXT,
  error     TEXT
);
