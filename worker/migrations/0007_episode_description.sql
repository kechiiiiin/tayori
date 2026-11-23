-- 段階3: 回の説明（ショーノート）を持つ（2026-11-24）
-- content:encoded → description → itunes:summary（Atom は content → summary、JSON Feed は content_html → content_text → summary）の
-- 最初に中身のあるものを HTML のまま入れる。UTF-8 で 50KB を超えた分は切る（parse.ts の DESCRIPTION_MAX_BYTES）。
-- 一覧の API には載せず、GET /api/episodes/:id だけが返す。
-- 既にある回は、次の取得で「説明が NULL なら埋める」（podcast.ts の upsertEpisodes）。
-- そのため番組の ETag／Last-Modified を消し、次の取得で条件なしに全文を読ませる（列の追加があるので wrangler の migrations で1回だけ流す）
ALTER TABLE episodes ADD COLUMN description TEXT;

UPDATE feeds SET etag = NULL, last_modified = NULL WHERE kind = 'podcast';
