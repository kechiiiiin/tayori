-- 端末ごとに「お知らせ（alert）を受け取るか」。アプリの「通知」スイッチ・通知の許可から決まる（PUT /api/devices の alerts）。
-- 0 でも登録は残し、サイレントプッシュ（番組に新しい回が入った cron で裏起動させる background）は送る
ALTER TABLE device_tokens ADD COLUMN alerts INTEGER NOT NULL DEFAULT 1;
