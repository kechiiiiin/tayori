// かけら帳 iOS の「読んだ記事」: GET /api/items/read-on?date=YYYY-MM-DD は read_at が JST のその日の記事を read_at 昇順で返す
import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, fixture } from "./helpers.ts";
import { jstDayRange } from "../src/store.ts";

async function withFeed(s: ReturnType<typeof setup>) {
  s.web.set("https://anikuma.example/feed", { body: fixture("rss2.xml") });
  await s.call("POST", "/api/feeds", { url: "https://anikuma.example/feed" });
  return (await s.call("GET", "/api/items")).json.items as any[];
}

test("jstDayRange: JST 0:00 は前日 UTC 15:00。暦に無い日・形違いは null", () => {
  assert.deepEqual(jstDayRange("2026-11-18"), { from: "2026-11-17T15:00:00.000Z", to: "2026-11-18T15:00:00.000Z" });
  assert.deepEqual(jstDayRange("2027-01-01"), { from: "2026-12-31T15:00:00.000Z", to: "2027-01-01T15:00:00.000Z" });
  for (const bad of ["", "2026-11-31", "2026-02-29", "2026-1-18", "2026/11/18", "2026-11-18T00:00", "abc"]) assert.equal(jstDayRange(bad), null, bad);
  assert.ok(jstDayRange("2028-02-29"));
});

test("read-on: JST 23:59 はその日、翌 0:00 は翌日。read_at 昇順・形", async () => {
  const s = setup();
  const [c, a, b] = await withFeed(s);
  await s.call("PUT", `/api/items/${b.id}/comment`, { comment: "あとで日記に" });
  s.clock.set("2026-11-18T14:59:59.999Z"); // JST 11/18 23:59:59.999
  await s.call("POST", `/api/items/${b.id}/read`);
  s.clock.set("2026-11-17T15:00:00.000Z"); // JST 11/18 0:00 ちょうど
  await s.call("POST", `/api/items/${a.id}/read`);
  s.clock.set("2026-11-18T15:00:00.000Z"); // JST 11/19 0:00 ちょうど
  await s.call("POST", `/api/items/${c.id}/read`);

  let r = await s.call("GET", "/api/items/read-on?date=2026-11-18");
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.items.map((i: any) => i.id), [a.id, b.id]);
  const it = r.json.items[1];
  assert.equal(it.title, b.title);
  assert.equal(it.url, b.url);
  assert.equal(it.feed_title, "アニクマ");
  assert.equal(it.read_at, "2026-11-18T14:59:59.999Z");
  assert.equal(it.comment, "あとで日記に");

  r = await s.call("GET", "/api/items/read-on?date=2026-11-19");
  assert.deepEqual(r.json.items.map((i: any) => i.id), [c.id]);
  r = await s.call("GET", "/api/items/read-on?date=2026-11-17");
  assert.deepEqual(r.json.items, []);
});

test("read-on: 未読に戻した記事は出ない。日付が不正なら 400。サービストークンが要る", async () => {
  const s = setup();
  const [, a] = await withFeed(s);
  await s.call("POST", `/api/items/${a.id}/read`);
  assert.equal((await s.call("GET", "/api/items/read-on?date=2026-11-18")).json.items.length, 1);
  await s.call("DELETE", `/api/items/${a.id}/read`);
  assert.equal((await s.call("GET", "/api/items/read-on?date=2026-11-18")).json.items.length, 0);
  assert.equal((await s.call("GET", "/api/items/read-on")).status, 400);
  assert.equal((await s.call("GET", "/api/items/read-on?date=2026-13-01")).status, 400);
  assert.equal((await s.call("GET", "/api/items/read-on?date=2026-11-18", undefined, null)).status, 401);
  assert.equal((await s.call("GET", "/api/items/read-on?date=2026-11-18", undefined, "user.jwt")).status, 403);
});
