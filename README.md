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
| ポッドキャスト（段階3） | `feeds.kind`（`article`／`podcast`）。番組の回は `items` に `enclosure_url`・`enclosure_type`・`duration_sec` つきで入る。**記事一覧・カテゴリの数・`GET /api/feeds`（既定）には出ない**。初回 20 件・控え・既読 90 日の対象外で、番組ごとに新しい順 **300 回**まで持つ（取得のたびに古い回から消す・コメントのある回は残す）。キュー・再生位置・自動追加・ダウンロードは iPhone の中（Worker と同期しない） |
| 段階2 | `feeds.rururu_paw` と `paw_queue` は作ってあるだけ（rururu の書き込み API 待ち） |

### API

| メソッド | パス | 本文・クエリ |
| --- | --- | --- |
| GET | `/api/items` | `state=unread\|commented\|all`・`category=<id>\|none`・`feed=<id>`・`before=<next>`・`limit` → `{ items, next }` |
| GET | `/api/items/read-on?date=YYYY-MM-DD` | `read_at` が JST のその日の記事を `read_at` 昇順で（かけら帳 iOS の「読んだ記事」）→ `{ items }`。日付が不正なら 400 `bad_date` |
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
| GET | `/api/podcasts` | 番組の一覧（段階3）→ `{ podcasts: [{ id, title, site_url, feed_url, image_url, last_fetched_at, last_error, episodes, latest_episode_id, latest_at }] }` |
| POST | `/api/podcasts` | `{ url }`（フィードの URL か番組のサイト）→ 201 `{ podcast, created: true }`／購読済みは 200。記事として購読済みなら番組へ移して取り直す（`converted: true`） |
| GET / DELETE | `/api/podcasts/:id` | 1番組／外す（回も消える） |
| GET | `/api/podcasts/:id/episodes` | その番組の回（新しい順）。`before`・`limit`・`after_id`（その id より後を昇順で）→ `{ episodes, next }` |
| GET | `/api/episodes` | 全番組の新着（新しい順）。クエリは同じ |

### 「ポッドキャスト」カテゴリを番組へ移す（段階3・一度だけ）

`migrations/0005_move_podcast_category.sql` は、カテゴリ「ポッドキャスト」のサイトを `kind = podcast` に移してカテゴリを消す。
`wrangler d1 migrations apply tayori --remote` で 0004 と一緒に流れるので、**本番へ流す前に中身と対象（カテゴリ名「ポッドキャスト」のサイト）を確かめる**。
移した番組は次の cron で最優先・条件なしで取り直され、回に音声の URL と長さが入る。

## ポッドキャスト（段階3・iPhone）

- 下のタブバーで「記事」「ポッドキャスト」を切り替える。記事のページは段階1・2 のまま
- ポッドキャストの上のタブ: キュー（メイン・サブ…の順）→ 新着 → 番組。キューは ＋ のメニューで作り、タブの長押しで名前を変える・左右へ・消す
- 回の右の ＋（か長押し）で、どのキューの先頭／末尾へ入れるかを選ぶ。キューの中は「並べ替え」・左スワイプで外す・右スワイプで別のキューへ
- 番組の画面で回の一覧と「新着: 自動で入れない／〇〇の先頭へ／末尾へ」。新着はアプリが前に出るたびに読み、番組の設定に従ってキューへ（7日より古い回・足した直後の過去回は入れない）
- 聴き終え＝最後まで再生した（途中で別の回へ移ったときは残り30秒未満なら聴き終え扱い）。キューから外れ、同じキューの先頭 → 空なら右隣のキュー（空のキューは飛ばす）の先頭へ。最後のキューまで聴き終えたら止まる
- キューにある回は自動でダウンロード（バックグラウンドの URLSession・既定は Wi-Fi のときだけ・＋ のメニューで「モバイル通信でもダウンロード」）。落としてあれば端末内のファイルで再生、聴き終えた・キューから外した回のファイルは消す
- 速度 0.5〜3.0 倍（0.1 刻み・全体で1つ）・15秒戻し／30秒送り・バックグラウンド再生・ロック画面とコントロールセンター・続きから再開。タブバーの上に小さなプレーヤー、押すと全画面
- キュー・再生位置・自動追加の設定・ダウンロードは端末の中（`Application Support/podcast-state.json`・`Episodes/`）。Worker とは同期しない
- 番組の追加は名前で探す（iTunes Search API・アプリから直接）か、フィードの URL

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

ポッドキャスト（段階3）の撮影・試験用: `-tayoriMainTab podcasts`（下のタブ）・`-tayoriPodcastReset`（端末内のキュー・ダウンロードを消して始める）・`-tayoriPodcastDemo`（seed の回でメイン／サブのキューを作る）・`-tayoriPodcastTab new|shows|sub`・`-tayoriPodcastShow <番組名>`・`-tayoriPodcastAdd <検索語>`・`-tayoriPodcastAddURL <URL>`・`-tayoriPodcastPlay`（最初のキューの先頭を再生）・`-tayoriPlayer open`（全画面プレーヤー）・`-tayoriSeekNearEnd <秒>`（回を読み込むたびに末尾の N 秒前へ＝キューの連鎖の UI テスト）。
`make test` はキューの決まり（QueueBook）のユニットテスト、`make uitest` は記事と段階3（`PodcastUITests`: 記事／ポッドキャストの切り替え・キューへの追加・メイン→サブ→停止の連鎖・速度と30秒送り）。

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
5. 「メイン」の新着のプッシュ: secret `APNS_KEY`（.p8 の中身）・`APNS_KEY_ID`・`APNS_TEAM_ID`（家族掲示板と同じ鍵・チームでよい）。`npx wrangler secret put APNS_KEY < AuthKey_XXXXXXXXXX.p8`。欠けていればプッシュだけ送らない。sandbox／本番は端末ごとにアプリが申告する

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
