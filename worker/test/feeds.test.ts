// 受け入れ条件3: POST /api/feeds はサイトの URL からフィードを見つける。見つからなければエラー。付け替え・外す・いますぐ
import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, fixture } from "./helpers.ts";

function site(s: ReturnType<typeof setup>) {
  s.web.set("https://blog.example.jp/", { body: fixture("site.html"), headers: { "Content-Type": "text/html; charset=utf-8" } });
  s.web.set("https://blog.example.jp/feed.xml?a=1&b=2", { status: 500 });
  s.web.set("https://blog.example.jp/atom.xml", { body: fixture("atom.xml") });
}

test("サイトの URL → <link rel=alternate> を上から試し、読めた最初のフィードを足す", async () => {
  const s = setup();
  site(s);
  const cat = (await s.call("POST", "/api/categories", { name: "日記・ブログ" })).json.category.id;
  const r = await s.call("POST", "/api/feeds", { url: "blog.example.jp/", category_id: cat });
  assert.equal(r.status, 201);
  assert.equal(r.json.created, true);
  assert.deepEqual(
    { ...r.json.feed, id: 0 },
    {
      id: 0,
      kind: "article",
      category_id: cat,
      title: "Zenn architecture",
      site_url: "https://zenn.example/topics/architecture",
      feed_url: "https://blog.example.jp/atom.xml",
      image_url: null,
      last_fetched_at: "2026-11-18T03:00:00.000Z",
      last_error: null,
      rururu_paw: false,
      unread: 2,
      created_at: "2026-11-18T03:00:00.000Z",
    },
  );
  assert.deepEqual(s.web.calls.map((c) => c.url), ["https://blog.example.jp/", "https://blog.example.jp/feed.xml?a=1&b=2", "https://blog.example.jp/atom.xml"]);
});

test("RSS の URL を直接貼ってもよい", async () => {
  const s = setup();
  s.web.set("https://anikuma.example/feed", { body: fixture("rss2.xml") });
  const r = await s.call("POST", "/api/feeds", { url: "https://anikuma.example/feed" });
  assert.equal(r.status, 201);
  assert.equal(r.json.feed.title, "アニクマ");
  assert.equal(r.json.feed.category_id, null);
  assert.equal(r.json.feed.unread, 3);
});

test("見つからない・取れないときはエラーで返し、何も足さない", async () => {
  const s = setup();
  s.web.set("https://plain.example/", { body: "<html><head><title>RSS なし</title></head><body></body></html>" });
  assert.deepEqual(await s.call("POST", "/api/feeds", { url: "https://plain.example/" }), { status: 422, json: { error: "feed_not_found" } });
  assert.deepEqual(await s.call("POST", "/api/feeds", { url: "https://down.example/" }), { status: 422, json: { error: "fetch_failed", detail: "HTTP 404" } });
  assert.equal(s.count("SELECT COUNT(*) AS n FROM feeds"), 0);
});

test("不正な URL・知らないカテゴリは 400（取りに行かない）", async () => {
  const s = setup();
  for (const url of ["", "   ", "javascript:alert(1)", "ftp://x.example/", "not a url", "localhost", 3]) {
    assert.deepEqual(await s.call("POST", "/api/feeds", { url }), { status: 400, json: { error: "bad_url" } }, String(url));
  }
  assert.deepEqual(await s.call("POST", "/api/feeds", { url: "https://x.example/", category_id: 99 }), { status: 400, json: { error: "bad_category" } });
  assert.deepEqual(await s.call("POST", "/api/feeds", { url: "https://x.example/", category_id: "1" }), { status: 400, json: { error: "bad_category" } });
  assert.equal(s.web.calls.length, 0);
});

test("もう購読しているフィードは足さずに 200 で返す（サイトの URL からでも）", async () => {
  const s = setup();
  site(s);
  const first = await s.call("POST", "/api/feeds", { url: "https://blog.example.jp/" });
  const again = await s.call("POST", "/api/feeds", { url: "https://blog.example.jp/atom.xml" });
  assert.equal(again.status, 200);
  assert.equal(again.json.created, false);
  assert.equal(again.json.feed.id, first.json.feed.id);
  const viaSite = await s.call("POST", "/api/feeds", { url: "https://blog.example.jp/" });
  assert.equal(viaSite.json.feed.id, first.json.feed.id);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM feeds"), 1);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items"), 2);
});

test("カテゴリの付け替え・未分類へ・外す（記事も消える）", async () => {
  const s = setup();
  s.web.set("https://anikuma.example/feed", { body: fixture("rss2.xml") });
  const id = (await s.call("POST", "/api/feeds", { url: "https://anikuma.example/feed" })).json.feed.id;
  const cat = (await s.call("POST", "/api/categories", { name: "仕事" })).json.category.id;
  assert.equal((await s.call("PATCH", `/api/feeds/${id}`, { category_id: cat })).json.feed.category_id, cat);
  assert.equal((await s.call("PATCH", `/api/feeds/${id}`, { category_id: null })).json.feed.category_id, null);
  assert.equal((await s.call("PATCH", `/api/feeds/${id}`, {})).status, 400);
  assert.equal((await s.call("PATCH", `/api/feeds/999`, { category_id: null })).status, 404);
  const item = (await s.call("GET", "/api/items")).json.items[0];
  await s.call("PUT", `/api/items/${item.id}/comment`, { comment: "メモ" });
  assert.deepEqual(await s.call("DELETE", `/api/feeds/${id}`), { status: 200, json: { ok: true } });
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items"), 0);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM item_tombstones"), 0);
  assert.equal((await s.call("DELETE", `/api/feeds/${id}`)).status, 404);
  assert.deepEqual((await s.call("GET", "/api/feeds")).json, { feeds: [] });
});

test("いますぐ取りに行く: 新しい記事が入り、結果を返す", async () => {
  const s = setup();
  s.web.set("https://anikuma.example/feed", { body: fixture("rss2.xml") });
  const id = (await s.call("POST", "/api/feeds", { url: "https://anikuma.example/feed" })).json.feed.id;
  s.web.set("https://anikuma.example/feed", { body: fixture("rss2.xml").replace("<item>", "<item><title>新着</title><guid>post-4</guid></item><item>") });
  const r = await s.call("POST", `/api/feeds/${id}/refresh`);
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.result, { status: "ok", added: 1 });
  assert.equal(r.json.feed.unread, 4);
  assert.equal((await s.call("POST", "/api/feeds/999/refresh")).status, 404);
});
