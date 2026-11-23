// 段階3 受け入れ条件1: 番組の enclosure・長さを保存し、記事一覧に混ざらず、番組・エピソード一覧の API が認証つきで動く
// 受け入れ条件2: 「ポッドキャスト」カテゴリの番組を kind=podcast へ移す SQL（0005）
// 2026-11-24 手直し: 回は episodes（上限なし・既知の回は書かない・ページング）。items から移す SQL（0006）
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setup, fixture, podcastWith } from "./helpers.ts";
import { makeDb } from "./d1shim.ts";
import { parseDuration, parseFeed } from "../src/parse.ts";
import { refreshFeed, runScheduled } from "../src/fetcher.ts";
import { getFeedRow } from "../src/store.ts";
import { upsertEpisodes } from "../src/podcast.ts";

const SHOW = "https://show.example/feed.xml";
/** node:sqlite の行（null プロトタイプ）を比べられる形に */
const plain = (x: unknown) => JSON.parse(JSON.stringify(x));

async function addShow(s: ReturnType<typeof setup>, url = SHOW, body = fixture("podcast-show.xml")) {
  s.web.set(url, { body, etag: '"s1"' });
  const r = await s.call("POST", "/api/podcasts", { url });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json.podcast.id as number;
}

test("parse: RSS の enclosure（音声を優先・相対 URL を解く）と itunes:duration を秒に。音声の無い回は今までの形", () => {
  const f = parseFeed(fixture("podcast-show.xml"), SHOW)!;
  const [e3, e2, e1, news] = f.items;
  assert.equal(e3.enclosure_url, "https://cdn.show.example/ep3.mp3");
  assert.equal(e3.enclosure_type, "audio/mpeg");
  assert.equal(e3.duration_sec, 3725);
  assert.equal(e2.enclosure_url, "https://show.example/audio/ep2.m4a");
  assert.equal(e2.duration_sec, 2550);
  assert.equal(e1.enclosure_url, "https://cdn.show.example/ep1.mp3", "画像の添付より音声");
  assert.equal(e1.duration_sec, 1800);
  assert.deepEqual(Object.keys(news).sort(), ["guid", "published_at", "title", "url"]);
});

test("parse: itunes:duration の書き方いろいろ", () => {
  assert.equal(parseDuration("3725"), 3725);
  assert.equal(parseDuration("62:05"), 3725);
  assert.equal(parseDuration("01:02:05"), 3725);
  assert.equal(parseDuration("1234.6"), 1235);
  assert.equal(parseDuration(""), null);
  assert.equal(parseDuration("abc"), null);
  assert.equal(parseDuration("0"), null);
});

test("parse: Atom の rel=enclosure と JSON Feed の attachments", () => {
  const atom = `<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>A</title><link href="https://a.example/"/>
    <entry><id>a1</id><title>回1</title><updated>2026-11-17T00:00:00Z</updated><link href="https://a.example/1"/>
    <link rel="enclosure" type="audio/mpeg" href="https://a.example/1.mp3"/></entry></feed>`;
  const a = parseFeed(atom, "https://a.example/atom")!.items[0];
  assert.equal(a.url, "https://a.example/1");
  assert.equal(a.enclosure_url, "https://a.example/1.mp3");
  const json = JSON.stringify({
    version: "https://jsonfeed.org/version/1.1",
    title: "J",
    items: [{ id: "j1", title: "回", url: "https://j.example/1", attachments: [{ url: "https://j.example/1.m4a", mime_type: "audio/mp4", duration_in_seconds: 61.4 }] }],
  });
  const j = parseFeed(json, "https://j.example/feed.json")!.items[0];
  assert.equal(j.enclosure_url, "https://j.example/1.m4a");
  assert.equal(j.enclosure_type, "audio/mp4");
  assert.equal(j.duration_sec, 61);
});

test("POST /api/podcasts: 番組として足し、回の音声・長さを保存する（カテゴリなし・音声の無い回は一覧に出ない）", async () => {
  const s = setup();
  const id = await addShow(s);
  const row = (await getFeedRow(s.db, id))!;
  assert.equal(row.kind, "podcast");
  assert.equal(row.category_id, null);
  const saved = plain(s.raw.prepare("SELECT guid, enclosure_url, enclosure_type, duration_sec FROM episodes WHERE feed_id = ? ORDER BY sort_at DESC").all(id));
  assert.deepEqual(saved, [
    { guid: "show-ep-3", enclosure_url: "https://cdn.show.example/ep3.mp3", enclosure_type: "audio/mpeg", duration_sec: 3725 },
    { guid: "show-ep-2", enclosure_url: "https://show.example/audio/ep2.m4a", enclosure_type: "audio/x-m4a", duration_sec: 2550 },
    { guid: "show-ep-1", enclosure_url: "https://cdn.show.example/ep1.mp3", enclosure_type: "audio/mpeg", duration_sec: 1800 },
  ]);
  // 音声の無い回は入れない。記事の表（items）には何も入らない
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items"), 0);
  // id は配信の古い順に増える
  const ids = plain(s.raw.prepare("SELECT guid FROM episodes ORDER BY id").all()).map((r: any) => r.guid);
  assert.deepEqual(ids, ["show-ep-1", "show-ep-2", "show-ep-3"]);
  const list = (await s.call("GET", "/api/podcasts")).json.podcasts;
  assert.equal(list.length, 1);
  assert.equal(list[0].title, "山の話のラジオ");
  assert.equal(list[0].image_url, "https://show.example/art.jpg");
  assert.equal(list[0].episodes, 3);
  assert.equal(typeof list[0].latest_episode_id, "number");
  const eps = (await s.call("GET", `/api/podcasts/${id}/episodes`)).json;
  assert.deepEqual(eps.episodes.map((e: any) => e.title), ["#3 冬の装備", "#2 秋の山小屋", "#1 はじめまして"]);
  assert.deepEqual(Object.keys(eps.episodes[0]).sort(), [
    "duration_sec", "enclosure_type", "enclosure_url", "feed_id", "feed_image_url", "feed_title", "id", "published_at", "sort_at", "title", "url",
  ]);
  assert.equal(eps.episodes[0].feed_image_url, "https://show.example/art.jpg");
  assert.equal(eps.next, null);
  // 同じ URL をもう一度 → 200 created: false
  const again = await s.call("POST", "/api/podcasts", { url: SHOW });
  assert.equal(again.status, 200);
  assert.equal(again.json.created, false);
  assert.equal(again.json.converted, false);
});

test("記事一覧・カテゴリの数・サイト一覧に番組の回が混ざらない", async () => {
  const s = setup();
  s.web.set("https://anikuma.example/feed", { body: fixture("rss2.xml") });
  await s.call("POST", "/api/feeds", { url: "https://anikuma.example/feed" });
  await addShow(s);
  for (const state of ["unread", "all"]) {
    const items = (await s.call("GET", `/api/items?state=${state}`)).json.items as any[];
    assert.equal(items.length, 3, state);
    assert.ok(items.every((i) => i.feed_title === "アニクマ"), state);
  }
  assert.equal((await s.call("GET", "/api/items?state=commented")).json.items.length, 0);
  assert.equal((await s.call("GET", "/api/items?category=none")).json.items.length, 3);
  const cats = (await s.call("GET", "/api/categories")).json;
  assert.deepEqual(cats.uncategorized, { unread: 3, commented: 0 });
  assert.deepEqual(cats.total, { unread: 3, commented: 0 });
  const feeds = (await s.call("GET", "/api/feeds")).json.feeds;
  assert.deepEqual(feeds.map((f: any) => [f.title, f.kind]), [["アニクマ", "article"]]);
  assert.deepEqual((await s.call("GET", "/api/feeds?kind=podcast")).json.feeds.map((f: any) => f.kind), ["podcast"]);
  assert.equal((await s.call("GET", "/api/feeds?kind=all")).json.feeds.length, 2);
  assert.equal((await s.call("GET", "/api/feeds?kind=x")).status, 400);
});

test("番組の回は上限なしに全部持ち、フィードから消えた回も消さない。控え・既読 90 日の対象外", async () => {
  const s = setup();
  const N = 1200;
  const id = await addShow(s, "https://pod.example/feed", podcastWith(N));
  assert.equal(s.count("SELECT COUNT(*) AS n FROM episodes WHERE feed_id = ?", id), N);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM item_tombstones"), 0);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items"), 0);
  assert.equal((await s.call("GET", `/api/podcasts/${id}`)).json.podcast.episodes, N);
  // 新しい 2 回だけ載り、古い回はフィードから落ちた → 足されて、落ちた回は残る
  s.clock.addDays(1);
  s.web.set("https://pod.example/feed", { body: podcastWith(N + 2, { start: "2026-11-20T00:00:00Z" }).replace(/<item><title>第([1-9]|[1-9]\d|[1-9]\d\d)回<\/title>.*?<\/item>/g, "") });
  const r = await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps);
  assert.deepEqual(r, { status: "ok", added: 2 });
  assert.equal(s.count("SELECT COUNT(*) AS n FROM episodes WHERE feed_id = ?", id), N + 2);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM episodes WHERE guid = 'e-1'"), 1, "フィードから消えた最初の回も残る");
  // 既読 90 日の掃除（cron）でも消えない
  s.clock.addDays(200);
  s.web.set("https://pod.example/feed", { status: 304 });
  const cron = await runScheduled(s.db, s.deps, 10);
  assert.equal(cron.purged, 0);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM episodes WHERE feed_id = ?", id), N + 2);
});

test("既知の回は書き込まない（同じ中身の取り直しで episodes への INSERT／UPDATE を出さない）", async () => {
  const s = setup();
  const id = await addShow(s, "https://pod.example/feed", podcastWith(500));
  const sqls: string[] = [];
  const prepare = s.db.prepare.bind(s.db);
  (s.db as any).prepare = (sql: string) => (sqls.push(sql), prepare(sql));
  const before = plain(s.raw.prepare("SELECT * FROM episodes ORDER BY id").all());
  s.web.set("https://pod.example/feed", { body: podcastWith(500) }); // ETag なし・同じ中身
  assert.deepEqual(await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps), { status: "ok", added: 0 });
  assert.deepEqual(sqls.filter((q) => /^\s*(INSERT|UPDATE)[^;]*episodes/i.test(q)), [], "episodes へ書かない");
  assert.deepEqual(plain(s.raw.prepare("SELECT * FROM episodes ORDER BY id").all()), before);
  // 1 回増えたら、その 1 回だけを INSERT する
  sqls.length = 0;
  s.web.set("https://pod.example/feed", { body: podcastWith(501, { start: "2026-11-19T00:00:00Z" }) });
  s.clock.addDays(1);
  assert.deepEqual(await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps), { status: "ok", added: 1 });
  assert.equal(sqls.filter((q) => /INSERT[^;]*episodes/i.test(q)).length, 1);
  assert.equal(sqls.filter((q) => /UPDATE[^;]*episodes/i.test(q)).length, 0);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM episodes"), 501);
});

test("大きいフィードは INSERT を分けて1回の batch で入れる（D1 の文の大きさに掛からない）", async () => {
  const s = setup();
  s.raw.prepare("INSERT INTO feeds (id, kind, title, feed_url, created_at) VALUES (99, 'podcast', 'X', 'https://x.example/', '2026-11-18T00:00:00.000Z')").run();
  let batches = 0;
  const batch = s.db.batch.bind(s.db);
  (s.db as any).batch = (st: any) => (batches++, batch(st));
  const parsed = parseFeed(podcastWith(950), "https://x.example/")!;
  assert.equal(await upsertEpisodes(s.db, 99, parsed.items, s.clock.now()), 950);
  assert.equal(batches, 1);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM episodes WHERE feed_id = 99"), 950);
  // 同じものをもう一度 → 0（batch も呼ばない）
  assert.equal(await upsertEpisodes(s.db, 99, parsed.items, s.clock.now()), 0);
  assert.equal(batches, 1);
});

test("番組のエピソード一覧は 30 件ずつ・before で続き・取りこぼし／重複なし（300 回を超える番組）", async () => {
  const s = setup();
  const N = 345;
  const id = await addShow(s, "https://pod.example/feed", podcastWith(N));
  const seen: string[] = [];
  let next: string | null = null;
  let pages = 0;
  do {
    const q: string = next ? `?before=${encodeURIComponent(next)}` : "";
    const r: any = (await s.call("GET", `/api/podcasts/${id}/episodes${q}`)).json;
    assert.ok(r.episodes.length <= 30);
    seen.push(...r.episodes.map((e: any) => e.title));
    next = r.next;
    pages++;
  } while (next);
  assert.equal(pages, Math.ceil(N / 30));
  assert.equal(seen.length, N);
  assert.equal(new Set(seen).size, N);
  assert.equal(seen[0], `第${N}回`);
  assert.equal(seen[N - 1], "第1回");
  // 全番組の新着も同じ形
  const all = (await s.call("GET", "/api/episodes")).json;
  assert.equal(all.episodes.length, 30);
  assert.ok(all.next);
});

test("取り直しで enclosure・長さ・題名が変わった回だけ書き換え、同じなら触らない", async () => {
  const s = setup();
  const id = await addShow(s);
  const before = plain(s.raw.prepare("SELECT * FROM episodes ORDER BY id").all());
  s.web.set(SHOW, { body: fixture("podcast-show.xml") }); // ETag なし・同じ中身
  assert.deepEqual(await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps), { status: "ok", added: 0 });
  assert.deepEqual(plain(s.raw.prepare("SELECT * FROM episodes ORDER BY id").all()), before);
  s.web.set(SHOW, { body: fixture("podcast-show.xml").replace("ep3.mp3", "ep3-fixed.mp3").replace("1:02:05", "1:02:10") });
  await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps);
  const e3 = plain(s.raw.prepare("SELECT enclosure_url, duration_sec FROM episodes WHERE guid = 'show-ep-3'").get());
  assert.deepEqual(e3, { enclosure_url: "https://cdn.show.example/ep3-fixed.mp3", duration_sec: 3730 });
});

test("記事として購読済みのフィードを番組として足すと移る（記事の回と控えを消し、過去回を episodes へ取り直す・コメントのある回は items に残す）", async () => {
  const s = setup();
  const url = "https://pod.example/feed";
  s.web.set(url, { body: podcastWith(30) });
  const added = await s.call("POST", "/api/feeds", { url });
  const id = added.json.feed.id as number;
  // 記事として入った回: 20 回は items・21 回目以降は控えへ。1 回にコメント
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items"), 20);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM item_tombstones"), 10);
  s.raw.prepare("UPDATE items SET comment = '残す' WHERE guid = 'e-30'").run();
  const r = await s.call("POST", "/api/podcasts", { url });
  assert.equal(r.status, 200);
  assert.equal(r.json.converted, true);
  assert.equal(r.json.podcast.episodes, 30);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM episodes WHERE feed_id = ?", id), 30);
  assert.deepEqual(plain(s.raw.prepare("SELECT guid, comment FROM items").all()), [{ guid: "e-30", comment: "残す" }]);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM item_tombstones"), 0);
  assert.equal((await s.call("GET", "/api/items?state=commented")).json.items.length, 0, "残した回は記事一覧に出ない");
  assert.equal((await getFeedRow(s.db, id))!.kind, "podcast");
  assert.equal((await s.call("GET", "/api/items?state=all")).json.items.length, 0);
});

test("GET /api/episodes: 全番組の新しい順・before で続き・after_id で「まだ見ていない回」を昇順で", async () => {
  const s = setup();
  const a = await addShow(s, "https://a.pod.example/feed", podcastWith(3, { prefix: "a", start: "2026-11-17T00:00:00Z", title: "A" }));
  const b = await addShow(s, "https://b.pod.example/feed", podcastWith(2, { prefix: "b", start: "2026-11-17T12:00:00Z", title: "B" }));
  const all = (await s.call("GET", "/api/episodes")).json;
  assert.deepEqual(all.episodes.map((e: any) => `${e.feed_title}${e.title}`), ["B第2回", "A第3回", "B第1回", "A第2回", "A第1回"]);
  const p1 = (await s.call("GET", "/api/episodes?limit=2")).json;
  assert.equal(p1.episodes.length, 2);
  const p2 = (await s.call("GET", `/api/episodes?limit=2&before=${encodeURIComponent(p1.next)}`)).json;
  assert.deepEqual(p2.episodes.map((e: any) => e.title), ["第1回", "第2回"]);
  // after_id
  const maxA = (await s.call("GET", `/api/podcasts/${a}`)).json.podcast.latest_episode_id;
  const after = (await s.call("GET", `/api/episodes?after_id=${maxA}`)).json.episodes;
  assert.deepEqual(after.map((e: any) => e.feed_id), [b, b]);
  assert.ok(after[0].id < after[1].id);
  const onlyA = (await s.call("GET", `/api/podcasts/${a}/episodes?after_id=0&limit=2`)).json;
  assert.equal(onlyA.episodes.length, 2);
  assert.equal(onlyA.next, String(onlyA.episodes[1].id));
  assert.equal((await s.call("GET", "/api/episodes?after_id=x")).status, 400);
  assert.equal((await s.call("GET", "/api/episodes?before=x")).status, 400);
});

test("番組の API は認証つき（トークンなし 401・許可外 403）。記事のフィードは番組の口で 404", async () => {
  const s = setup();
  const id = await addShow(s);
  for (const path of ["/api/podcasts", `/api/podcasts/${id}`, `/api/podcasts/${id}/episodes`, "/api/episodes"]) {
    assert.equal((await s.call("GET", path, undefined, null)).status, 401, path);
    assert.equal((await s.call("GET", path, undefined, "other.jwt")).status, 403, path);
    assert.equal((await s.call("GET", path)).status, 200, path);
  }
  assert.equal((await s.call("POST", "/api/podcasts", { url: SHOW }, null)).status, 401);
  s.web.set("https://anikuma.example/feed", { body: fixture("rss2.xml") });
  const art = (await s.call("POST", "/api/feeds", { url: "https://anikuma.example/feed" })).json.feed.id;
  assert.equal((await s.call("GET", `/api/podcasts/${art}`)).status, 404);
  assert.equal((await s.call("GET", `/api/podcasts/${art}/episodes`)).status, 404);
  assert.equal((await s.call("DELETE", `/api/podcasts/${art}`)).status, 404);
});

test("番組にカテゴリは付けられない。DELETE /api/podcasts/:id で回ごと外れる", async () => {
  const s = setup();
  const id = await addShow(s);
  const cat = (await s.call("POST", "/api/categories", { name: "仕事" })).json.category.id;
  assert.equal((await s.call("PATCH", `/api/feeds/${id}`, { category_id: cat })).status, 400);
  assert.equal((await s.call("DELETE", `/api/podcasts/${id}`)).status, 200);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM episodes"), 0);
  assert.equal((await s.call("GET", "/api/podcasts")).json.podcasts.length, 0);
  assert.equal((await s.call("POST", "/api/podcasts", { url: "nope" })).status, 400);
});

test("移行 SQL 0005: 「ポッドキャスト」カテゴリの番組を kind=podcast へ・カテゴリを消し並びを詰める。他は触らない", () => {
  const { raw } = makeDb(["migrations/0001_init.sql", "migrations/0002_feed_image.sql", "migrations/0003_device_tokens.sql", "migrations/0004_podcast.sql"]);
  const t = "2026-11-19T00:00:00.000Z";
  raw.exec(`
    INSERT INTO categories (id, name, sort, created_at) VALUES (1, 'メイン', 0, '${t}'), (2, 'ポッドキャスト', 1, '${t}'), (3, 'ブログ', 2, '${t}');
    INSERT INTO feeds (id, category_id, title, feed_url, etag, last_modified, last_fetched_at, created_at) VALUES
      (1, 1, '日記', 'https://a.example/feed', '"x"', 'Mon', '${t}', '${t}'),
      (2, 2, 'いつまじラジオ', 'https://p1.example/rss', '"y"', 'Tue', '${t}', '${t}'),
      (3, 2, 'コテンラジオ', 'https://p2.example/rss', NULL, NULL, '${t}', '${t}'),
      (4, 3, 'リリース情報', 'https://b.example/feed', NULL, NULL, '${t}', '${t}');
    INSERT INTO items (id, feed_id, guid, title, fetched_at, sort_at, read_at, comment) VALUES
      (1, 1, 'a1', '記事', '${t}', '${t}', NULL, NULL),
      (2, 2, 'p1', '#1', '${t}', '${t}', '${t}', 'あとで聴く');
    INSERT INTO item_tombstones (feed_id, guid, created_at) VALUES (1, 'old-a', '${t}'), (2, 'old-p', '${t}');
    INSERT INTO paw_queue (item_id, queued_at) VALUES (1, '${t}'), (2, '${t}');
  `);
  raw.exec(readFileSync("migrations/0005_move_podcast_category.sql", "utf8"));
  assert.deepEqual(plain(raw.prepare("SELECT id, kind, category_id, etag, last_modified, last_fetched_at FROM feeds ORDER BY id").all()), [
    { id: 1, kind: "article", category_id: 1, etag: '"x"', last_modified: "Mon", last_fetched_at: t },
    { id: 2, kind: "podcast", category_id: null, etag: null, last_modified: null, last_fetched_at: null },
    { id: 3, kind: "podcast", category_id: null, etag: null, last_modified: null, last_fetched_at: null },
    { id: 4, kind: "article", category_id: 3, etag: null, last_modified: null, last_fetched_at: t },
  ]);
  assert.deepEqual(plain(raw.prepare("SELECT id, name, sort FROM categories ORDER BY sort").all()), [
    { id: 1, name: "メイン", sort: 0 },
    { id: 3, name: "ブログ", sort: 1 },
  ]);
  assert.deepEqual(plain(raw.prepare("SELECT feed_id, guid FROM item_tombstones").all()), [{ feed_id: 1, guid: "old-a" }]);
  assert.deepEqual(plain(raw.prepare("SELECT item_id FROM paw_queue").all()), [{ item_id: 1 }]);
  // 回とコメントは消さない
  assert.deepEqual(plain(raw.prepare("SELECT id, comment FROM items ORDER BY id").all()), [{ id: 1, comment: null }, { id: 2, comment: "あとで聴く" }]);
  // もう一度流しても変わらない（カテゴリが無ければ何もしない）
  const snap = plain(raw.prepare("SELECT * FROM feeds ORDER BY id").all());
  raw.exec(readFileSync("migrations/0005_move_podcast_category.sql", "utf8"));
  assert.deepEqual(plain(raw.prepare("SELECT * FROM feeds ORDER BY id").all()), snap);
});

test("移した番組は次の cron で最優先に取り直され、回に enclosure が入る", async () => {
  const s = setup();
  const url = "https://pod.example/feed";
  s.web.set("https://anikuma.example/feed", { body: fixture("rss2.xml") });
  await s.call("POST", "/api/feeds", { url: "https://anikuma.example/feed" });
  s.web.set(url, { body: podcastWith(25), etag: '"p"' });
  const id = (await s.call("POST", "/api/feeds", { url })).json.feed.id;
  const cat = (await s.call("POST", "/api/categories", { name: "ポッドキャスト" })).json.category.id;
  await s.call("PATCH", `/api/feeds/${id}`, { category_id: cat });
  s.raw.exec(readFileSync("migrations/0005_move_podcast_category.sql", "utf8"));
  s.web.calls = [];
  s.clock.addDays(1);
  const r = await runScheduled(s.db, s.deps, 1);
  assert.equal(r.fetched, 1);
  assert.equal(s.web.calls[0].url, url);
  assert.equal(s.web.calls[0].headers["if-none-match"], undefined, "条件なしで全文を取り直す");
  // 0006 のあとは、移った番組を取り直すと episodes に全回が入る
  s.raw.exec(readFileSync("migrations/0006_episodes.sql", "utf8"));
  assert.equal(s.count("SELECT COUNT(*) AS n FROM episodes WHERE feed_id = ?", id), 25);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM items WHERE feed_id = ?", id), 0);
  assert.equal((await s.call("GET", "/api/categories")).json.categories.length, 0);
});

const BEFORE_0006 = ["0001_init", "0002_feed_image", "0003_device_tokens", "0004_podcast", "0005_move_podcast_category"].map((m) => `migrations/${m}.sql`);

/** 0005 まで当てた本番の形: 記事 1 本・番組 2 本（上限で消えた回の id が items の連番の先にある） */
function before0006() {
  const { raw, db } = makeDb(BEFORE_0006);
  const t = "2026-11-20T00:00:00.000Z";
  raw.exec(`
    INSERT INTO feeds (id, kind, category_id, title, feed_url, etag, last_modified, created_at) VALUES
      (1, 'article', NULL, '日記', 'https://a.example/feed', '"a"', 'Mon', '${t}'),
      (2, 'podcast', NULL, 'いつまじラジオ', 'https://p1.example/rss', '"p"', 'Tue', '${t}'),
      (3, 'podcast', NULL, 'コテンラジオ', 'https://p2.example/rss', NULL, NULL, '${t}');
    INSERT INTO items (id, feed_id, guid, url, title, published_at, fetched_at, sort_at, read_at, comment, enclosure_url, enclosure_type, duration_sec) VALUES
      (1, 1, 'a1', 'https://a.example/1', '記事', '${t}', '${t}', '${t}', '${t}', NULL, NULL, NULL, NULL),
      (2, 2, 'p1-1', NULL, '#1', '2026-11-01T00:00:00.000Z', '${t}', '2026-11-01T00:00:00.000Z', NULL, NULL, 'https://cdn.example/1.mp3', 'audio/mpeg', 600),
      (3, 2, 'p1-2', 'https://p1.example/2', '#2', '2026-11-08T00:00:00.000Z', '${t}', '2026-11-08T00:00:00.000Z', '${t}', 'あとで聴き直す', 'https://cdn.example/2.mp3', 'audio/mpeg', 700),
      (4, 2, 'p1-news', NULL, 'お知らせ', '${t}', '${t}', '${t}', NULL, NULL, NULL, NULL, NULL),
      (5, 3, 'p2-1', NULL, '第1回', '${t}', '${t}', '${t}', NULL, NULL, 'https://cdn2.example/1.m4a', 'audio/x-m4a', NULL),
      (6, 1, 'a2', NULL, '記事2', '${t}', '${t}', '${t}', NULL, 'メモ', NULL, NULL, NULL),
      (900, 3, 'p2-gone', NULL, '上限で消えた回', '${t}', '${t}', '${t}', NULL, NULL, 'https://cdn2.example/0.m4a', NULL, NULL);
    DELETE FROM items WHERE id = 900;
    INSERT INTO item_tombstones (feed_id, guid, created_at) VALUES (1, 'old-a', '${t}'), (2, 'old-p', '${t}');
    INSERT INTO paw_queue (item_id, queued_at) VALUES (1, '${t}'), (2, '${t}');
  `);
  return { raw, db };
}

function snapshot(raw: ReturnType<typeof makeDb>["raw"]) {
  return {
    episodes: plain(raw.prepare("SELECT * FROM episodes ORDER BY id").all()),
    items: plain(raw.prepare("SELECT * FROM items ORDER BY id").all()),
    tombstones: plain(raw.prepare("SELECT feed_id, guid FROM item_tombstones ORDER BY feed_id, guid").all()),
    paw: plain(raw.prepare("SELECT item_id FROM paw_queue ORDER BY item_id").all()),
    feeds: plain(raw.prepare("SELECT id, kind, etag, last_modified FROM feeds ORDER BY id").all()),
  };
}

test("移行 SQL 0006: 番組の回を id ごと episodes へ・コメントのない回は items から消す・コメントつきは items に残す・2回流しても同じ", async () => {
  const { raw, db } = before0006();
  const sql = readFileSync("migrations/0006_episodes.sql", "utf8");
  raw.exec(sql);
  const after = snapshot(raw);
  assert.deepEqual(
    after.episodes.map((e: any) => [e.id, e.feed_id, e.guid, e.url, e.title, e.enclosure_url, e.duration_sec]),
    [
      [2, 2, "p1-1", null, "#1", "https://cdn.example/1.mp3", 600],
      [3, 2, "p1-2", "https://p1.example/2", "#2", "https://cdn.example/2.mp3", 700],
      [5, 3, "p2-1", null, "第1回", "https://cdn2.example/1.m4a", null],
    ],
  );
  assert.equal(after.episodes[1].sort_at, "2026-11-08T00:00:00.000Z");
  // 記事 2 本と、コメントつきの番組の回（id 3）だけが items に残る。音声の無い番組の回（お知らせ）は消える
  assert.deepEqual(after.items.map((i: any) => [i.id, i.comment]), [[1, null], [3, "あとで聴き直す"], [6, "メモ"]]);
  assert.deepEqual(after.tombstones, [{ feed_id: 1, guid: "old-a" }]);
  assert.deepEqual(after.paw, [{ item_id: 1 }]);
  assert.deepEqual(after.feeds, [
    { id: 1, kind: "article", etag: '"a"', last_modified: "Mon" },
    { id: 2, kind: "podcast", etag: null, last_modified: null },
    { id: 3, kind: "podcast", etag: null, last_modified: null },
  ]);
  // 残したコメントつきの回は記事一覧・数に出ない
  const { listItems, listCategories } = await import("../src/store.ts");
  assert.deepEqual((await listItems(db, { state: "commented" })).items.map((i) => i.id), [6]);
  assert.deepEqual((await listCategories(db)).uncategorized, { unread: 1, commented: 1 });
  // 2 回目: 同じ
  raw.exec(sql);
  assert.deepEqual(snapshot(raw), after);
  // これから入る回の id は、items でこれまでに配った id（上限で消えた 900）より大きい（取得は 0007 の列を使うので当ててから）
  raw.exec(readFileSync("migrations/0007_episode_description.sql", "utf8"));
  const parsed = parseFeed(podcastWith(3, { prefix: "p2" }), "https://p2.example/rss")!;
  await upsertEpisodes(db, 3, parsed.items, new Date("2026-11-21T00:00:00Z"));
  const fresh = plain(raw.prepare("SELECT id, guid FROM episodes WHERE feed_id = 3 AND guid != 'p2-1' ORDER BY id").all());
  assert.equal(fresh.length, 2);
  assert.ok(fresh.every((e: any) => e.id > 900), JSON.stringify(fresh));
});

test("移行 SQL 0006: 番組が無い・回が無い DB でも流れる", () => {
  const { raw } = makeDb(BEFORE_0006);
  raw.exec(readFileSync("migrations/0006_episodes.sql", "utf8"));
  raw.exec(readFileSync("migrations/0006_episodes.sql", "utf8"));
  assert.equal(Number((raw.prepare("SELECT COUNT(*) AS n FROM episodes").get() as any).n), 0);
});
