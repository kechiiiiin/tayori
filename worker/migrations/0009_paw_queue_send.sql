-- 段階2: rururu への paw キュー（設計: jinsei vault hestia/projects/RSSフィーダー設計.md「段階2: rururu への paw」）
-- feeds.rururu_paw と paw_queue(item_id, queued_at, sent_at, error) は 0001 で作ってある。送った・飛ばした結果を残す列を足す
--   rururu_item_id: 送れたときの rururu 側の item の id（POST /api/paw_queue/:item_id/sent）
--   skipped_at・skip_reason: 送らずに外したとき（not_in_rururu・already_pawed など。POST /api/paw_queue/:item_id/skip）
ALTER TABLE paw_queue ADD COLUMN rururu_item_id INTEGER;
ALTER TABLE paw_queue ADD COLUMN skipped_at TEXT;
ALTER TABLE paw_queue ADD COLUMN skip_reason TEXT;
-- 未送信・未スキップを積んだ順に引く
CREATE INDEX paw_queue_pending ON paw_queue (sent_at, skipped_at, queued_at);
