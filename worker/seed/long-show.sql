-- 無限スクロールの試験用: 345 回ある番組（npm run seed のあとに `npx wrangler d1 execute tayori --local --file seed/long-show.sql`。ローカルだけ）
-- 回の題名は「長寿 第N回」（N = 1〜345・新しいほど大きい）。音声は seed の Rebuild の回を借りる
DELETE FROM episodes WHERE feed_id = 11;
DELETE FROM feeds WHERE id = 11;
INSERT INTO feeds (id,kind,category_id,title,site_url,feed_url,image_url,last_fetched_at,last_error,created_at)
VALUES (11,'podcast',NULL,'長寿番組（試験）','https://long.example/','https://long.example/rss','https://rebuild.fm/images/icon1400.jpg',
        strftime('%Y-%m-%dT%H:%M:%fZ','now'),NULL,strftime('%Y-%m-%dT%H:%M:%fZ','now','-400 days'));
WITH RECURSIVE n(k) AS (SELECT 1 UNION ALL SELECT k + 1 FROM n WHERE k < 345)
INSERT INTO episodes (feed_id,guid,url,title,published_at,fetched_at,sort_at,enclosure_url,enclosure_type,duration_sec)
SELECT 11, 'long-' || k, NULL, '長寿 第' || k || '回',
       strftime('%Y-%m-%dT%H:%M:%fZ','now', '-' || (345 - k + 30) || ' days'),
       strftime('%Y-%m-%dT%H:%M:%fZ','now'),
       strftime('%Y-%m-%dT%H:%M:%fZ','now', '-' || (345 - k + 30) || ' days'),
       'https://cache.rebuild.fm/podcast-ep436.mp3','audio/mpeg', 600 + k
  FROM n;
