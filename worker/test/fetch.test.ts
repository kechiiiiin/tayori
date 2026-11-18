// 受け入れ条件2: 取得（304 で書き込まない・重複を作らない・初回は 20 件まで・エラーを残す）と cron
import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, fixture, rssWith } from "./helpers.ts";
import { refreshDue, refreshFeed, runScheduled } from "../src/fetcher.ts";
import { getFeedRow } from "../src/store.ts";

const FEED = "https://anikuma.example/feed";

async function added(s: ReturnType<typeof setup>, url = FEED, body = fixture("rss2.xml"), etag?: string) {
  s.web.set(url, { body, etag, headers: { "Content-Type": "application/rss+xml; charset=utf-8", "Last-Modified": "Tue, 17 Nov 2026 00:00:00 GMT" } });
  const r = await s.call("POST", "/api/feeds", { url });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json.feed.id as number;
}

test("初めて足したフィードは新しい順に 20 件だけ未読で入り、残りは次の取得でも戻らない", async () => {
  const s = setup();
  const id = await added(s, "https://many.example/feed", rssWith(30));
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items WHERE feed_id = ? AND read_at IS NULL", id), 20);
  const titles = (s.raw.prepare("SELECT title FROM items ORDER BY sort_at DESC").all() as { title: string }[]).map((r) => r.title);
  assert.equal(titles[0], "記事 1");
  assert.equal(titles[19], "記事 20");
  // 次の取得: p-1〜p-31（p-21〜p-30 は初回に控えへ回したもの、p-31 だけが初めて見る記事）
  s.clock.addDays(1);
  s.web.set("https://many.example/feed", { body: rssWith(31) });
  const r = await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps);
  assert.deepEqual(r, { status: "ok", added: 1 });
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items WHERE feed_id = ?", id), 21);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items WHERE guid = 'p-31'"), 1);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items WHERE guid = 'p-21'"), 0);
});

test("同じ記事を何度取っても重複しない（feed_id, guid）", async () => {
  const s = setup();
  const id = await added(s);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items"), 3);
  for (let i = 0; i < 3; i++) await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items"), 3);
  // フィードの中で同じ guid が2回出ても1件
  const dup = fixture("rss2.xml").replace("</channel>", "<item><title>重複</title><guid>post-3</guid></item></channel>");
  s.web.set(FEED, { body: dup });
  await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items"), 3);
});

test("ETag／Last-Modified を覚えて条件付きで取り、304 なら記事も ETag も書き換えない", async () => {
  const s = setup();
  const id = await added(s, FEED, fixture("rss2.xml"), '"v1"');
  let row = (await getFeedRow(s.db, id))!;
  assert.equal(row.etag, '"v1"');
  assert.equal(row.last_modified, "Tue, 17 Nov 2026 00:00:00 GMT");
  const before = s.raw.prepare("SELECT * FROM items ORDER BY id").all();
  s.clock.addDays(1);
  const r = await refreshFeed(s.db, row, s.deps);
  assert.deepEqual(r, { status: "not_modified", added: 0 });
  const last = s.web.calls.at(-1)!;
  assert.equal(last.headers["if-none-match"], '"v1"');
  assert.equal(last.headers["if-modified-since"], "Tue, 17 Nov 2026 00:00:00 GMT");
  assert.deepEqual(s.raw.prepare("SELECT * FROM items ORDER BY id").all(), before);
  row = (await getFeedRow(s.db, id))!;
  assert.equal(row.etag, '"v1"');
  assert.equal(row.last_fetched_at, "2026-11-19T03:00:00.000Z");
});

test("取れないフィードは last_error に残り、次に取れたら消える。記事は消えない", async () => {
  const s = setup();
  const id = await added(s);
  s.web.set(FEED, { status: 503 });
  assert.deepEqual(await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps), { status: "error", error: "HTTP 503", added: 0 });
  let f = (await s.call("GET", "/api/feeds")).json.feeds[0];
  assert.equal(f.last_error, "HTTP 503");
  assert.equal(f.unread, 3);
  s.web.set(FEED, { throws: true });
  await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps);
  assert.equal((await getFeedRow(s.db, id))!.last_error, "通信エラー");
  s.web.set(FEED, { body: "<html>メンテナンス中</html>" });
  await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps);
  assert.equal((await getFeedRow(s.db, id))!.last_error, "フィードとして読めません");
  s.web.set(FEED, { body: fixture("rss2.xml") });
  await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps);
  f = (await s.call("GET", "/api/feeds")).json.feeds[0];
  assert.equal(f.last_error, null);
});

test("未来の日付の記事は取った時刻で並べる（一覧の先頭に居座らない）", async () => {
  const s = setup();
  const body = rssWith(1, { start: "2027-01-01T00:00:00Z" });
  await added(s, "https://many.example/feed", body);
  const row = s.raw.prepare("SELECT published_at, sort_at FROM items").get() as { published_at: string; sort_at: string };
  assert.equal(row.published_at, "2027-01-01T00:00:00.000Z");
  assert.equal(row.sort_at, "2026-11-18T03:00:00.000Z");
});

test("cron: 取ってから時間がたった順に上限まで取りに行く", async () => {
  const s = setup();
  const a = await added(s, "https://a.example/feed", rssWith(1, { prefix: "a" }));
  s.clock.addDays(1);
  const b = await added(s, "https://b.example/feed", rssWith(1, { prefix: "b" }));
  s.web.calls = [];
  s.clock.addDays(1);
  const r = await refreshDue(s.db, s.deps, 1);
  assert.equal(r.fetched, 1);
  assert.deepEqual(s.web.calls.map((c) => c.url), ["https://a.example/feed"]);
  await refreshDue(s.db, s.deps, 1);
  assert.deepEqual(s.web.calls.map((c) => c.url), ["https://a.example/feed", "https://b.example/feed"]);
  assert.ok(a && b);
});

test("cron: 古い既読を消してから取りに行き、消した記事は戻らない", async () => {
  const s = setup();
  const id = await added(s);
  const item = (await s.call("GET", "/api/items")).json.items[0];
  await s.call("POST", `/api/items/${item.id}/read`);
  s.clock.addDays(91);
  const r = await runScheduled(s.db, s.deps, 10);
  assert.equal(r.purged, 1);
  assert.equal(r.fetched, 1);
  assert.equal(r.added, 0);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items WHERE feed_id = ?", id), 2);
});
