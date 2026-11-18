# 便り（tayori）

iPhone・iPad（・Apple Silicon の Mac）で読む自作の RSS フィーダー。段階1は rururu を意識しない、ふつうのフィーダー。

- 一覧は**未読だけ・新しい順**。上のタブで「未読／コメントあり／すべて」、その下のカテゴリで絞る
- 記事をタップすると**アプリ内の Safari 画面**で書いた人のページが開く。**開いただけでは既読にしない**
- 戻ってくると下に「既読にする」「コメント」のバー。一覧で左へスワイプしても既読。既読は取り消せる
- コメントは記事ごとの自分だけのメモ。既読にしても「コメントあり」から見返せる
- 既読でコメントの無い記事は 90 日で消える。未読は消さない
- サイトは URL を貼るか、Safari の共有から足す（`<link rel="alternate">` から RSS／Atom を探す）。カテゴリは1サイトに1つ

```
worker/   Cloudflare Worker（Hono・TypeScript）＋ D1 マイグレーション＋テスト（node --test）
ios/      XcodeGen の project.yml・SwiftUI アプリ・共有拡張（Share Extension）
scripts/  setup-access.sh（Access を作る一回きり）・import-rururu.mjs（rururu の購読を流し込む一回きり）
docs/screenshots/  シミュレータの実画面
```

設計: jinsei vault `hestia/projects/RSSフィーダー設計.md`（モック `RSSフィーダー-モック.html`）

## 仕組み（要点）

| 項目 | どうなっているか |
| --- | --- |
| 取得 | cron（30 分ごと）で、取ってから時間がたった順に `FETCH_PER_RUN` 本。`ETag`／`Last-Modified` で条件付き GET、304 なら記事に触らない |
| 形式 | RSS 2.0・RSS 1.0（RDF）・Atom・JSON Feed（`fast-xml-parser`） |
| 重複 | `(feed_id, guid)` で除く。guid が無ければ URL、それも無ければ題名 |
| 初回 | 足したフィードは新しい順に 20 件だけ未読で入れる。残りは `item_tombstones`（見た guid の控え）へ |
| 90 日 | 既読から 90 日たち、コメントの無い記事を cron で消す。guid は控えに残すので、フィードにまだ載っていても未読で戻らない |
| 取得エラー | `feeds.last_error` に残し、アプリのサイト一覧に「取得できません」 |
| 認証 | Cloudflare Access のサービストークン（アーカイブに埋め込み・Keychain の値があればそちら優先）。Worker は関所（sekisho）の `verify(token, aud, { allowServiceTokens: true })` で確かめ、Client ID を `ACCESS_SERVICE_CLIENT_IDS` と照合（無し・不正は 401、許可外は 403） |
| 段階2 | `feeds.rururu_paw` と `paw_queue` は作ってあるだけ（rururu の書き込み API 待ち） |

### API

| メソッド | パス | 本文・クエリ |
| --- | --- | --- |
| GET | `/api/items` | `state=unread\|commented\|all`・`category=<id>\|none`・`feed=<id>`・`before=<next>`・`limit` → `{ items, next }` |
| POST / DELETE | `/api/items/:id/read` | 既読にする／戻す → `{ item }` |
| PUT | `/api/items/:id/comment` | `{ comment }`（空文字で消す）→ `{ item }` |
| GET | `/api/categories` | → `{ categories: [{ id, name, sort, unread, commented }], uncategorized, total }` |
| POST | `/api/categories` | `{ name }` |
| PATCH | `/api/categories/:id` | `{ name?, sort? }`（sort は何番目に置くか・0 から） |
| DELETE | `/api/categories/:id` | 中のサイトは未分類へ |
| GET | `/api/feeds` | → `{ feeds: [{ id, category_id, title, site_url, feed_url, last_fetched_at, last_error, unread }] }` |
| POST | `/api/feeds` | `{ url, category_id? }` → 201 `{ feed, created: true }`／購読済みは 200 `created: false`／見つからない 422 `feed_not_found`・取れない 422 `fetch_failed` |
| PATCH | `/api/feeds/:id` | `{ category_id }`（null で未分類） |
| DELETE | `/api/feeds/:id` | 記事とコメントも消える |
| POST | `/api/feeds/:id/refresh` | いますぐ取りに行く |

## 開発

```sh
cd worker
npm install
npm run check          # tsc --noEmit と テスト

cp .dev.vars.example .dev.vars   # ローカルは認証を迂回（localhost かつ --define __LOCAL_DEV__ のときだけ）
npm run dev            # http://127.0.0.1:8792
npm run seed           # モックと同じ並びのデモデータ（ローカルの D1 だけ）

cd ../ios
make sim               # xcodegen generate → シミュレータ向けビルド
make shots             # iPhone と iPad のシミュレータで撮る（docs/screenshots/）
```

DEBUG ビルドだけ、起動引数 `-tayoriBaseURL http://127.0.0.1:8792` でつなぎ先を差し替えられる（App Group に写すので共有拡張も同じ先を見る）。
スクリーンショット用に `-tayoriDemo opened|comment|safari`・`-tayoriTab commented`・`-tayoriScreen sites`・`-tayoriSharePreview <URL>`（共有拡張と同じ画面をアプリ内に出す）・`-tayoriShareAutoAdd <カテゴリ名>` がある。

IME: URL 欄・カテゴリ名の欄は `IMESafeTextField`（UITextField の `markedTextRange` が残っている間の Return は確定だけで送らない）。コメント欄は複数行で Return は改行（送信はボタンだけ）。

## セットアップ（初回）

値はここに書かない。secret は `wrangler secret put`、ローカルは `.dev.vars`（コミットしない）。

【Keisuke・ブラウザ】は無し。【Keisuke・ターミナル】は 2 の1回だけ（キーチェーンへの保存が自動モードで止まるため）。

### 1. D1・デプロイ【ヘスティア・コマンド】

```sh
cd worker
npx wrangler d1 create tayori                  # → database_id を wrangler.toml へ（いまは 0000… の仮）
npx wrangler d1 migrations apply tayori --remote
npx wrangler deploy                            # Custom Domain tayori.kechiiiiin.com・cron */30
```

`FETCH_PER_RUN`（wrangler.toml の `[vars]`・既定 15）は、Workers Free の「1 回の実行で subrequest 50」（fetch と D1 の問い合わせの合計）に収まる量。Workers Paid なら 100〜200 に上げてよい。
ポッドキャストのフィード（5〜10MB）を毎回読むと Free の CPU 10ms を超えることがある。取れないサイトが続くなら Paid を考える。

### 2. Cloudflare Access【Keisuke・ターミナル・1回】

```sh
bash scripts/setup-access.sh
```

1. サービストークン `tayori-app` を作る（あれば回し直す）→ キーチェーン `tayori-token`（`client-id`／`client-secret`）
2. Access アプリ「tayori」（Self-hosted）で `tayori.kechiiiiin.com` を守る
3. ポリシーを「Service Auth でこのトークンだけ」にする
4. Worker の secret `CF_ACCESS_AUD`・`ACCESS_SERVICE_CLIENT_IDS` を入れる

要るもの: キーチェーン `cloudflare-admin-token`（Access 編集）・`cloudflare-deploy-token`（Workers 編集）。関所（sekisho）が同じアカウントにデプロイ済みであること（Service Binding `SEKISHO`）。

### 3. iOS・TestFlight【ヘスティア・コマンド】

- bundle id: アプリ `jp.kechiiiiin.tayori`、共有拡張 `jp.kechiiiiin.tayori.share`
- App Group: `group.jp.kechiiiiin.tayori`（両方。サービストークンもこのグループの Keychain に入る）
- iPhone と iPad（`TARGETED_DEVICE_FAMILY` 1,2）。iPad は全方向の向き（`UISupportedInterfaceOrientations~ipad`）
- Team ID は `~/.config/kazoku-keijiban/team-id`（家族掲示板と同じチーム）を Makefile が `TAYORI_TEAM_ID` に流す
- App Store Connect のアプリの枠を先に作る

```sh
cd ios
cp Release.example.env Release.local.env   # 家族掲示板と同じ API キー（値は画面に出さず写す）
make archive     # キーチェーン tayori-token → Secrets.xcconfig（gitignore）→ archive
make upload
```

トークンを回し直したら（`scripts/setup-access.sh`）、`make archive` で作り直して上げ直す。古いビルドの埋め込み値は無効になる。

### 4. rururu の購読を流し込む【ヘスティア・コマンド・1回】

```sh
node scripts/import-rururu.mjs --dry-run   # 件数と一覧だけ（便りには送らない）
node scripts/import-rururu.mjs             # 本番へ。全部「未分類」に入る
```

rururu の App Password は rururu CLI の設定（`~/.config/rururu/config.json`）から読むだけで、表示・保存し直さない。rururu へは読むだけ。

## 決まっていない

- Mac は同じアプリ（iPad 版を Apple Silicon で動かす）で済むか・TestFlight で入るか
- 段階2: rururu の書き込み API の有無、rururu に無いサイトへの paw、送るタイミング
