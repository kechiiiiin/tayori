// 受け入れ条件4: 既読は POST /read でだけ付き、取り消せる
// 受け入れ条件6: コメントは既読と別に残り「コメントあり」で引ける。既読でコメント無しは 90 日で消える
import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, fixture, rssWith } from "./helpers.ts";
import { purgeOld } from "../src/store.ts";

async function withFeed(s: ReturnType<typeof setup>) {
  s.web.set("https://anikuma.example/feed", { body: fixture("rss2.xml") });
  await s.call("POST", "/api/feeds", { url: "https://anikuma.example/feed" });
  return (await s.call("GET", "/api/items")).json.items as any[];
}

test("一覧: 既定は未読だけ・新しい順（日付の無い記事は取った時刻で並ぶ）。記事の形", async () => {
  const s = setup();
  const items = await withFeed(s);
  assert.deepEqual(items.map((i) => i.title), ["日付の無い記事", "1on1 を「報告会」にしないための三つの問い", '設計レビューで "決めない" を決める']);
  assert.deepEqual(Object.keys(items[0]).sort(), [
    "category_id", "comment", "comment_updated_at", "feed_id", "feed_title", "id", "published_at", "read_at", "sort_at", "title", "url",
  ]);
  assert.equal(items[0].feed_title, "アニクマ");
  assert.equal(items[0].read_at, null);
});

test("一覧を開く・GET するだけでは既読にならない", async () => {
  const s = setup();
  await withFeed(s);
  for (let i = 0; i < 3; i++) await s.call("GET", "/api/items?state=all");
  await s.call("GET", "/api/categories");
  await s.call("GET", "/api/feeds");
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items WHERE read_at IS NOT NULL"), 0);
});

test("POST /read で既読、DELETE /read で未読に戻る。もう一度 POST しても時刻は変わらない", async () => {
  const s = setup();
  const [, a] = await withFeed(s);
  let r = await s.call("POST", `/api/items/${a.id}/read`);
  assert.equal(r.status, 200);
  assert.equal(r.json.item.read_at, "2026-11-18T03:00:00.000Z");
  assert.equal((await s.call("GET", "/api/items")).json.items.length, 2);
  s.clock.addDays(1);
  r = await s.call("POST", `/api/items/${a.id}/read`);
  assert.equal(r.json.item.read_at, "2026-11-18T03:00:00.000Z");
  r = await s.call("DELETE", `/api/items/${a.id}/read`);
  assert.equal(r.json.item.read_at, null);
  assert.equal((await s.call("GET", "/api/items")).json.items.length, 3);
  assert.equal((await s.call("POST", "/api/items/999/read")).status, 404);
  assert.equal((await s.call("DELETE", "/api/items/abc/read")).status, 404);
});

test("コメント: 既読とは別。「コメントあり」は既読でも未読でも出る。空文字で消える", async () => {
  const s = setup();
  const [c, a, b] = await withFeed(s);
  let r = await s.call("PUT", `/api/items/${a.id}/comment`, { comment: "  二つ目の問いは来週試す\r\n  " });
  assert.equal(r.json.item.comment, "二つ目の問いは来週試す");
  assert.equal(r.json.item.comment_updated_at, "2026-11-18T03:00:00.000Z");
  assert.equal(r.json.item.read_at, null);
  await s.call("PUT", `/api/items/${b.id}/comment`, { comment: "タイムラインを先に" });
  await s.call("POST", `/api/items/${b.id}/read`);
  const commented = (await s.call("GET", "/api/items?state=commented")).json.items;
  assert.deepEqual(commented.map((i: any) => [i.id, i.read_at !== null]), [[a.id, false], [b.id, true]]);
  r = await s.call("PUT", `/api/items/${a.id}/comment`, { comment: "   " });
  assert.equal(r.json.item.comment, null);
  assert.equal(r.json.item.comment_updated_at, null);
  assert.deepEqual((await s.call("GET", "/api/items?state=commented")).json.items.map((i: any) => i.id), [b.id]);
  assert.equal((await s.call("PUT", `/api/items/${c.id}/comment`, { comment: 1 })).status, 400);
  assert.equal((await s.call("PUT", `/api/items/${c.id}/comment`, { comment: "あ".repeat(4001) })).status, 400);
  assert.equal((await s.call("PUT", "/api/items/999/comment", { comment: "x" })).status, 404);
});

test("90 日: 既読でコメント無しだけ消える。未読・コメントあり・既読 90 日未満は残る", async () => {
  const s = setup();
  const [c, a, b] = await withFeed(s);
  await s.call("POST", `/api/items/${a.id}/read`); // 既読・コメント無し → 消える
  await s.call("POST", `/api/items/${b.id}/read`);
  await s.call("PUT", `/api/items/${b.id}/comment`, { comment: "残す" }); // 既読・コメントあり → 残る
  // c は未読 → 残る
  s.clock.addDays(89);
  assert.equal(await purgeOld(s.db, s.clock.now()), 0);
  s.clock.addDays(2);
  assert.equal(await purgeOld(s.db, s.clock.now()), 1);
  const left = (s.raw.prepare("SELECT id FROM items ORDER BY id").all() as { id: number }[]).map((r) => r.id);
  assert.deepEqual(left, [b.id, c.id].sort((x, y) => x - y));
});

test("絞り込み: すべて・フィード・ページ送り（カーソル）", async () => {
  const s = setup();
  s.web.set("https://many.example/feed", { body: rssWith(5) });
  const many = (await s.call("POST", "/api/feeds", { url: "https://many.example/feed" })).json.feed.id;
  await withFeed(s);
  const all = (await s.call("GET", "/api/items?state=all")).json.items;
  assert.equal(all.length, 8);
  const byFeed = (await s.call("GET", `/api/items?feed=${many}`)).json.items;
  assert.equal(byFeed.length, 5);
  const p1 = (await s.call("GET", "/api/items?state=all&limit=3")).json;
  assert.equal(p1.items.length, 3);
  const p2 = (await s.call("GET", `/api/items?state=all&limit=3&before=${encodeURIComponent(p1.next)}`)).json;
  const p3 = (await s.call("GET", `/api/items?state=all&limit=3&before=${encodeURIComponent(p2.next)}`)).json;
  assert.equal(p3.next, null);
  assert.deepEqual([...p1.items, ...p2.items, ...p3.items].map((i: any) => i.id), all.map((i: any) => i.id));
  assert.equal((await s.call("GET", "/api/items?state=nope")).status, 400);
  assert.equal((await s.call("GET", "/api/items?before=garbage")).status, 400);
});
