-- ポッドキャストの番組アートワーク（RSS のチャンネルの itunes:image@href）。取得のたびに上書き。無いフィードは NULL
ALTER TABLE feeds ADD COLUMN image_url TEXT;
