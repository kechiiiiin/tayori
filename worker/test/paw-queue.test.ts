// 段階2: rururu への paw キュー。rururu_paw=1 のサイトの記事を既読にしたら積む・戻したら外す・sent／skip で一覧から消える
import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, fixture, podcastWith } from "./helpers.ts";
import { purgeOld } from "../src/store.ts";

async function withFeed(s: ReturnType<typeof setup>) {
  s.web.set("https://anikuma.example/feed", { body: fixture("rss2.xml") });
  const feed = (await s.call("POST", "/api/feeds", { url: "https://anikuma.example/feed" })).json.feed;
  const items = (await s.call("GET", "/api/items")).json.items as any[];
  return { feed, items };
}

test("GET /api/feeds に rururu_paw（既定 false）・PATCH で切り替え", async () => {
  const s = setup();
  const { feed } = await withFeed(s);
  assert.equal(feed.rururu_paw, false);
  let r = await s.call("PATCH", `/api/feeds/${feed.id}`, { rururu_paw: true });
  assert.equal(r.status, 200);
  assert.equal(r.json.feed.rururu_paw, true);
  assert.equal(r.json.feed.category_id, null); // カテゴリは触らない
  assert.equal((await s.call("GET", "/api/feeds")).json.feeds[0].rururu_paw, true);
  assert.equal((await s.call("PATCH", `/api/feeds/${feed.id}`, { rururu_paw: 1 })).status, 400);
  assert.equal((await s.call("PATCH", `/api/feeds/${feed.id}`, {})).status, 400);
  assert.equal((await s.call("PATCH", "/api/feeds/999", { rururu_paw: true })).status, 404);
  // カテゴリと一緒に
  const cat = (await s.call("POST", "/api/categories", { name: "日記" })).json.category.id;
  r = await s.call("PATCH", `/api/feeds/${feed.id}`, { category_id: cat, rururu_paw: false });
  assert.equal(r.json.feed.category_id, cat);
  assert.equal(r.json.feed.rururu_paw, false);
});

test("オン→既読で積まれる（形）・二度既読にしても1件・既読戻しで消える", async () => {
  const s = setup();
  const { feed, items } = await withFeed(s);
  const [a] = items;
  await s.call("PATCH", `/api/feeds/${feed.id}`, { rururu_paw: true });
  await s.call("PUT", `/api/items/${a.id}/comment`, { comment: "あとで" });
  await s.call("POST", `/api/items/${a.id}/read`);
  s.clock.addDays(1);
  await s.call("POST", `/api/items/${a.id}/read`);
  let q = (await s.call("GET", "/api/paw_queue")).json.queue;
  assert.equal(q.length, 1);
  assert.deepEqual(Object.keys(q[0]).sort(), [
    "comment", "feed_id", "feed_title", "feed_url", "item_id", "queued_at", "read_at", "site_url", "title", "url",
  ]);
  assert.equal(q[0].item_id, a.id);
  assert.equal(q[0].url, a.url);
  assert.equal(q[0].feed_title, "アニクマ");
  assert.equal(q[0].feed_url, "https://anikuma.example/feed");
  assert.equal(q[0].comment, "あとで");
  assert.equal(q[0].queued_at, "2026-11-18T03:00:00.000Z");
  // コメントは送る時点のもの
  await s.call("PUT", `/api/items/${a.id}/comment`, { comment: "書き直した" });
  q = (await s.call("GET", "/api/paw_queue")).json.queue;
  assert.equal(q[0].comment, "書き直した");
  await s.call("DELETE", `/api/items/${a.id}/read`);
  assert.equal((await s.call("GET", "/api/paw_queue")).json.queue.length, 0);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM paw_queue"), 0);
});

test("オフのサイトは積まれない・オンにしても過去の既読は遡らない・オフにすると未送信は外れる", async () => {
  const s = setup();
  const { feed, items } = await withFeed(s);
  const [a, b, c] = items;
  await s.call("POST", `/api/items/${a.id}/read`);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM paw_queue"), 0);
  await s.call("PATCH", `/api/feeds/${feed.id}`, { rururu_paw: true });
  assert.equal(s.count("SELECT COUNT(*) AS n FROM paw_queue"), 0);
  await s.call("POST", `/api/items/${a.id}/read`); // もう既読のまま → 積まない
  assert.equal(s.count("SELECT COUNT(*) AS n FROM paw_queue"), 0);
  await s.call("POST", `/api/items/${b.id}/read`);
  await s.call("POST", `/api/items/${c.id}/read`);
  await s.call("POST", `/api/paw_queue/${c.id}/sent`, { rururu_item_id: 1555110 });
  await s.call("PATCH", `/api/feeds/${feed.id}`, { rururu_paw: false });
  assert.equal((await s.call("GET", "/api/paw_queue")).json.queue.length, 0);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM paw_queue WHERE sent_at IS NOT NULL"), 1); // 送った控えは残る
});

test("sent: rururu_item_id を控え一覧から消える・既読を戻しても控えは残り、再既読で積み直さない", async () => {
  const s = setup();
  const { feed, items } = await withFeed(s);
  const [a] = items;
  await s.call("PATCH", `/api/feeds/${feed.id}`, { rururu_paw: true });
  await s.call("POST", `/api/items/${a.id}/read`);
  assert.equal((await s.call("POST", `/api/paw_queue/${a.id}/sent`, {})).status, 400);
  assert.equal((await s.call("POST", `/api/paw_queue/${a.id}/sent`, { rururu_item_id: "x" })).status, 400);
  assert.equal((await s.call("POST", "/api/paw_queue/999/sent", { rururu_item_id: 1 })).status, 404);
  s.clock.addDays(1);
  let r = await s.call("POST", `/api/paw_queue/${a.id}/sent`, { rururu_item_id: "1555110" });
  assert.equal(r.status, 200);
  assert.equal((await s.call("GET", "/api/paw_queue")).json.queue.length, 0);
  const row = s.raw.prepare("SELECT * FROM paw_queue WHERE item_id = ?").get(a.id) as any;
  assert.equal(row.rururu_item_id, 1555110);
  assert.equal(row.sent_at, "2026-11-19T03:00:00.000Z");
  assert.equal((await s.call("POST", `/api/paw_queue/${a.id}/sent`, { rururu_item_id: 1 })).status, 409);
  assert.equal((await s.call("POST", `/api/paw_queue/${a.id}/skip`, { reason: "already_pawed" })).status, 409);
  await s.call("DELETE", `/api/items/${a.id}/read`);
  await s.call("POST", `/api/items/${a.id}/read`);
  assert.equal((await s.call("GET", "/api/paw_queue")).json.queue.length, 0);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM paw_queue"), 1);
});

test("skip: 理由を控え一覧から消える。あとで送れたら sent にできる", async () => {
  const s = setup();
  const { feed, items } = await withFeed(s);
  const [a, b] = items;
  await s.call("PATCH", `/api/feeds/${feed.id}`, { rururu_paw: true });
  await s.call("POST", `/api/items/${a.id}/read`);
  await s.call("POST", `/api/items/${b.id}/read`);
  assert.equal((await s.call("POST", `/api/paw_queue/${a.id}/skip`, {})).status, 400);
  assert.equal((await s.call("POST", `/api/paw_queue/${a.id}/skip`, { reason: "not_in_rururu" })).status, 200);
  const q = (await s.call("GET", "/api/paw_queue")).json.queue;
  assert.deepEqual(q.map((x: any) => x.item_id), [b.id]);
  const row = s.raw.prepare("SELECT skip_reason, skipped_at FROM paw_queue WHERE item_id = ?").get(a.id) as any;
  assert.equal(row.skip_reason, "not_in_rururu");
  assert.equal((await s.call("POST", `/api/paw_queue/${a.id}/sent`, { rururu_item_id: 7 })).status, 200);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM paw_queue WHERE item_id = ? AND skipped_at IS NULL AND sent_at IS NOT NULL", a.id), 1);
});

test("番組は rururu_paw をオンにできない", async () => {
  const s = setup();
  s.web.set("https://pod.example/feed", { body: podcastWith(3) });
  const p = (await s.call("POST", "/api/podcasts", { url: "https://pod.example/feed" })).json.podcast;
  assert.equal((await s.call("PATCH", `/api/feeds/${p.id}`, { rururu_paw: true })).status, 400);
});

test("90 日の掃除: まだ送っていないキューの記事は残す", async () => {
  const s = setup();
  const { feed, items } = await withFeed(s);
  const [a, b] = items;
  await s.call("PATCH", `/api/feeds/${feed.id}`, { rururu_paw: true });
  await s.call("POST", `/api/items/${a.id}/read`);
  await s.call("POST", `/api/items/${b.id}/read`);
  await s.call("POST", `/api/paw_queue/${b.id}/sent`, { rururu_item_id: 1 });
  s.clock.addDays(91);
  assert.equal(await purgeOld(s.db, s.clock.now()), 1);
  assert.deepEqual((await s.call("GET", "/api/paw_queue")).json.queue.map((x: any) => x.item_id), [a.id]);
});
