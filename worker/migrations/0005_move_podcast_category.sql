-- 段階3: 「ポッドキャスト」カテゴリのサイトをポッドキャストの番組（kind = podcast）へ移し、カテゴリを消す。
-- ⚠️ 本番（--remote）へはヘスティアが中身を確かめてから流す。カテゴリが無い DB（テスト・新規）では何もしない
--
-- 1. カテゴリ「ポッドキャスト」のサイトを podcast にし、カテゴリを外す。
--    etag／last_modified／last_fetched_at を消して、次の cron で最優先・条件なしで全文を取り直す
--    （今までの回に enclosure・長さを埋め、初回 20 件より前の回も番組の上限まで入れるため）
UPDATE feeds
   SET kind = 'podcast', category_id = NULL, etag = NULL, last_modified = NULL, last_fetched_at = NULL
 WHERE category_id IN (SELECT id FROM categories WHERE name = 'ポッドキャスト');

-- 2. 番組の回は控え（初回 21 件目以降・90 日で消した回）を使わない。過去回を一覧で見られるよう消す
DELETE FROM item_tombstones WHERE feed_id IN (SELECT id FROM feeds WHERE kind = 'podcast');

-- 3. rururu への paw の対象からも外す（番組の回は記事ページに出ないため）
DELETE FROM paw_queue WHERE item_id IN (SELECT i.id FROM items i JOIN feeds f ON f.id = i.feed_id WHERE f.kind = 'podcast');

-- 4. カテゴリを消し、残りの並びを 0 から詰め直す
DELETE FROM categories WHERE name = 'ポッドキャスト';
UPDATE categories SET sort = (SELECT COUNT(*) FROM categories c2 WHERE c2.sort < categories.sort OR (c2.sort = categories.sort AND c2.id < categories.id));
