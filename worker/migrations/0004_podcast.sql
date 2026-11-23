-- 段階3: ポッドキャスト（設計: jinsei vault hestia/projects/RSSフィーダー設計.md「段階3」）
-- feeds.kind: article（記事・今までどおり）／podcast（ポッドキャストの番組。記事一覧・カテゴリの数には出ない）
ALTER TABLE feeds ADD COLUMN kind TEXT NOT NULL DEFAULT 'article' CHECK (kind IN ('article', 'podcast'));
CREATE INDEX feeds_kind ON feeds (kind);

-- エピソードの音声（RSS の <enclosure>・Atom の rel=enclosure・JSON Feed の attachments）と長さ（itunes:duration を秒に）
-- 記事のフィードでも enclosure があれば入る（表示には使わない）
ALTER TABLE items ADD COLUMN enclosure_url TEXT;
ALTER TABLE items ADD COLUMN enclosure_type TEXT;
ALTER TABLE items ADD COLUMN duration_sec INTEGER;
-- 番組ごとのエピソード一覧（新しい順）
CREATE INDEX items_feed_sort ON items (feed_id, sort_at DESC, id DESC);
