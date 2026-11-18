// 受け入れ条件5: カテゴリを作る・名前を変える・並べ替える・消す（中のサイトは未分類へ）。一覧を絞れ、未読数が合う
import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, rssWith } from "./helpers.ts";

async function cats(s: ReturnType<typeof setup>) {
  return (await s.call("GET", "/api/categories")).json;
}

test("作る: 足した順に後ろへ。名前は1〜40文字", async () => {
  const s = setup();
  const r = await s.call("POST", "/api/categories", { name: "  仕事  " });
  assert.equal(r.status, 201);
  assert.deepEqual(r.json.category, { id: 1, name: "仕事", sort: 0, unread: 0, commented: 0 });
  await s.call("POST", "/api/categories", { name: "日記・ブログ" });
  await s.call("POST", "/api/categories", { name: "山" });
  assert.deepEqual((await cats(s)).categories.map((c: any) => [c.name, c.sort]), [["仕事", 0], ["日記・ブログ", 1], ["山", 2]]);
  for (const name of ["", "   ", "あ".repeat(41), 5, null]) {
    assert.deepEqual(await s.call("POST", "/api/categories", { name }), { status: 400, json: { error: "bad_name" } });
  }
});

test("名前を変える・並べ替える（何番目に置くか）", async () => {
  const s = setup();
  for (const name of ["仕事", "日記・ブログ", "山"]) await s.call("POST", "/api/categories", { name });
  let r = await s.call("PATCH", "/api/categories/3", { sort: 0 });
  assert.deepEqual(r.json.categories.map((c: any) => [c.name, c.sort]), [["山", 0], ["仕事", 1], ["日記・ブログ", 2]]);
  r = await s.call("PATCH", "/api/categories/3", { sort: 99, name: "山歩き" });
  assert.deepEqual(r.json.categories.map((c: any) => [c.name, c.sort]), [["仕事", 0], ["日記・ブログ", 1], ["山歩き", 2]]);
  assert.equal((await s.call("PATCH", "/api/categories/1", { sort: -1 })).status, 400);
  assert.equal((await s.call("PATCH", "/api/categories/1", { name: "" })).status, 400);
  assert.equal((await s.call("PATCH", "/api/categories/9", { name: "x" })).status, 404);
});

test("消す: 中のサイトは未分類へ移り、記事は残る", async () => {
  const s = setup();
  const work = (await s.call("POST", "/api/categories", { name: "仕事" })).json.category.id;
  s.web.set("https://a.example/feed", { body: rssWith(3, { prefix: "a" }) });
  const feed = (await s.call("POST", "/api/feeds", { url: "https://a.example/feed", category_id: work })).json.feed.id;
  const r = await s.call("DELETE", `/api/categories/${work}`);
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.categories, []);
  assert.deepEqual(r.json.uncategorized, { unread: 3, commented: 0 });
  const f = (await s.call("GET", "/api/feeds")).json.feeds.find((x: any) => x.id === feed);
  assert.equal(f.category_id, null);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items"), 3);
  assert.equal((await s.call("DELETE", `/api/categories/${work}`)).status, 404);
});

test("カテゴリで一覧を絞れ、未読数・コメント数がカテゴリ・未分類・合計で合う", async () => {
  const s = setup();
  const work = (await s.call("POST", "/api/categories", { name: "仕事" })).json.category.id;
  const blog = (await s.call("POST", "/api/categories", { name: "日記・ブログ" })).json.category.id;
  await s.call("POST", "/api/categories", { name: "山" });
  s.web.set("https://a.example/feed", { body: rssWith(4, { prefix: "a" }) });
  s.web.set("https://b.example/feed", { body: rssWith(2, { prefix: "b" }) });
  s.web.set("https://c.example/feed", { body: rssWith(3, { prefix: "c" }) });
  await s.call("POST", "/api/feeds", { url: "https://a.example/feed", category_id: work });
  await s.call("POST", "/api/feeds", { url: "https://b.example/feed", category_id: blog });
  await s.call("POST", "/api/feeds", { url: "https://c.example/feed" });

  const workItems = (await s.call("GET", `/api/items?category=${work}`)).json.items;
  assert.equal(workItems.length, 4);
  assert.ok(workItems.every((i: any) => i.category_id === work));
  assert.equal((await s.call("GET", "/api/items?category=none")).json.items.length, 3);

  await s.call("POST", `/api/items/${workItems[0].id}/read`);
  await s.call("PUT", `/api/items/${workItems[0].id}/comment`, { comment: "メモ" });
  await s.call("PUT", `/api/items/${workItems[1].id}/comment`, { comment: "メモ" });
  const c = await cats(s);
  assert.deepEqual(c.categories.map((x: any) => [x.name, x.unread, x.commented]), [["仕事", 3, 2], ["日記・ブログ", 2, 0], ["山", 0, 0]]);
  assert.deepEqual(c.uncategorized, { unread: 3, commented: 0 });
  assert.deepEqual(c.total, { unread: 8, commented: 2 });
  assert.equal((await s.call("GET", "/api/items")).json.items.length, c.total.unread);
  assert.equal((await s.call("GET", `/api/items?state=commented&category=${work}`)).json.items.length, 2);
  assert.equal((await s.call("GET", "/api/items?category=abc")).status, 400);
});
