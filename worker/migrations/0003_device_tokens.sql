-- プッシュ通知（「メイン」の新着）を送る端末。アプリが通知をオンにしている間だけ登録される（オフで DELETE）
-- environment: development（Xcode・devicectl で入れた開発署名 → sandbox）／production（TestFlight・App Store）
CREATE TABLE device_tokens (
  token       TEXT PRIMARY KEY,                       -- APNs の端末トークン（16進・小文字）
  environment TEXT NOT NULL DEFAULT 'production' CHECK (environment IN ('development', 'production')),
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
