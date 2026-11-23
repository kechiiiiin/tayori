// 2026-11-24 回の詳細ページ: 説明（ショーノート）を保存し、GET /api/episodes/:id で返す（一覧には載せない）
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setup, podcastWith } from "./helpers.ts";
import { makeDb } from "./d1shim.ts";
import { clipDescription, DESCRIPTION_MAX_BYTES, parseFeed } from "../src/parse.ts";
import { refreshFeed } from "../src/fetcher.ts";
import { getFeedRow } from "../src/store.ts";

const plain = (x: unknown) => JSON.parse(JSON.stringify(x));
const FEED = "https://pod.example/feed";

/** 説明の付いた3回の RSS（content:encoded・description・itunes:summary をそれぞれ一番手にする） */
function showWithNotes(o: { ep3?: string } = {}) {
  return `<?xml version="1.0"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/">
<channel><title>説明つき</title><link>https://pod.example/</link>
<item><title>第3回</title><guid>n-3</guid><pubDate>Wed, 18 Nov 2026 00:00:00 GMT</pubDate>
  <enclosure url="https://cdn.pod.example/3.mp3" type="audio/mpeg"/>
  <description>短い説明3</description><itunes:summary>要約3</itunes:summary>
  <content:encoded><![CDATA[${o.ep3 ?? '<p>本文3 <a href="https://ex.example/3">リンク</a></p>'}]]></content:encoded></item>
<item><title>第2回</title><guid>n-2</guid><pubDate>Wed, 11 Nov 2026 00:00:00 GMT</pubDate>
  <enclosure url="https://cdn.pod.example/2.mp3" type="audio/mpeg"/>
  <description>&lt;p&gt;説明2&lt;br/&gt;改行&lt;/p&gt;</description><itunes:summary>要約2</itunes:summary></item>
<item><title>第1回</title><guid>n-1</guid><pubDate>Wed, 04 Nov 2026 00:00:00 GMT</pubDate>
  <enclosure url="https://cdn.pod.example/1.mp3" type="audio/mpeg"/>
  <description>   </description><itunes:summary>要約1だけ</itunes:summary></item>
<item><title>お知らせ</title><guid>n-news</guid><description>音声なし</description></item>
</channel></rss>`;
}

test("parse: 説明は content:encoded → description → itunes:summary の順。空は飛ばす。音声の無い回は持たない", () => {
  const [e3, e2, e1, news] = parseFeed(showWithNotes(), FEED)!.items;
  assert.equal(e3.description, '<p>本文3 <a href="https://ex.example/3">リンク</a></p>');
  assert.equal(e2.description, "<p>説明2<br/>改行</p>", "エスケープされた HTML は戻して HTML のまま");
  assert.equal(e1.description, "要約1だけ");
  assert.equal("description" in news, false);
});

test("parse: Atom は content → summary、JSON Feed は content_html → content_text → summary", () => {
  const atom = `<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>A</title>
    <entry><id>a1</id><title>回1</title><updated>2026-11-17T00:00:00Z</updated><summary>要約</summary>
    <content type="html">&lt;p&gt;本文&lt;/p&gt;</content><link rel="enclosure" type="audio/mpeg" href="https://a.example/1.mp3"/></entry>
    <entry><id>a2</id><title>回2</title><updated>2026-11-16T00:00:00Z</updated><summary>要約だけ</summary>
    <link rel="enclosure" type="audio/mpeg" href="https://a.example/2.mp3"/></entry></feed>`;
  assert.deepEqual(parseFeed(atom, "https://a.example/")!.items.map((i) => i.description), ["<p>本文</p>", "要約だけ"]);
  const att = [{ url: "https://j.example/1.mp3", mime_type: "audio/mpeg" }];
  const json = JSON.stringify({
    version: "https://jsonfeed.org/version/1.1",
    title: "J",
    items: [
      { id: "1", title: "a", content_html: "<p>h</p>", content_text: "t", summary: "s", attachments: att },
      { id: "2", title: "b", content_text: "t", summary: "s", attachments: att },
      { id: "3", title: "c", summary: "s", attachments: att },
    ],
  });
  assert.deepEqual(parseFeed(json, "https://j.example/")!.items.map((i) => i.description), ["<p>h</p>", "t", "s"]);
});

test("説明は UTF-8 で 50KB までに切る（文字の途中・書きかけのタグや実体参照で終わらない）", () => {
  assert.equal(DESCRIPTION_MAX_BYTES, 51200);
  assert.equal(clipDescription(""), null);
  assert.equal(clipDescription(null), null);
  assert.equal(clipDescription(" <p>x</p> "), "<p>x</p>");
  const ja = "あ".repeat(20000); // 60000 バイト
  const c1 = clipDescription(ja)!;
  assert.ok(new TextEncoder().encode(c1).length <= DESCRIPTION_MAX_BYTES);
  assert.equal(c1, "あ".repeat(Math.floor(DESCRIPTION_MAX_BYTES / 3)));
  const tag = "x".repeat(DESCRIPTION_MAX_BYTES - 5) + '<a href="https://e.example/">y</a>';
  assert.equal(clipDescription(tag), "x".repeat(DESCRIPTION_MAX_BYTES - 5));
  const ent = "x".repeat(DESCRIPTION_MAX_BYTES - 3) + "&amp;zzz";
  assert.equal(clipDescription(ent), "x".repeat(DESCRIPTION_MAX_BYTES - 3));
  // フィードから読むときも切る
  const big = parseFeed(showWithNotes({ ep3: "<p>" + "い".repeat(30000) + "</p>" }), FEED)!.items[0];
  assert.ok(new TextEncoder().encode(big.description!).length <= DESCRIPTION_MAX_BYTES);
});

test("取得で説明を保存し、GET /api/episodes/:id で返す。一覧には載せない。無い id は 404", async () => {
  const s = setup();
  s.web.set(FEED, { body: showWithNotes() });
  const id = (await s.call("POST", "/api/podcasts", { url: FEED })).json.podcast.id;
  const list = (await s.call("GET", `/api/podcasts/${id}/episodes`)).json.episodes;
  assert.equal(list.length, 3);
  assert.ok(list.every((e: any) => !("description" in e)), "一覧には説明を載せない");
  assert.ok((await s.call("GET", "/api/episodes")).json.episodes.every((e: any) => !("description" in e)));
  const r = await s.call("GET", `/api/episodes/${list[0].id}`);
  assert.equal(r.status, 200);
  assert.equal(r.json.episode.title, "第3回");
  assert.equal(r.json.episode.feed_title, "説明つき");
  assert.equal(r.json.episode.enclosure_url, "https://cdn.pod.example/3.mp3");
  assert.equal(r.json.episode.description, '<p>本文3 <a href="https://ex.example/3">リンク</a></p>');
  assert.deepEqual(Object.keys(r.json.episode).sort(), [...Object.keys(list[0]), "description"].sort());
  assert.equal((await s.call("GET", "/api/episodes/999999")).status, 404);
  assert.equal((await s.call("GET", "/api/episodes/abc")).status, 404);
});

test("GET /api/episodes/:id は認証つき（トークンなし 401・否認 401・許可外 403）", async () => {
  const s = setup();
  s.web.set(FEED, { body: showWithNotes() });
  await s.call("POST", "/api/podcasts", { url: FEED });
  const eid = Number((s.raw.prepare("SELECT MIN(id) AS n FROM episodes").get() as any).n);
  assert.equal((await s.call("GET", `/api/episodes/${eid}`, undefined, null)).status, 401);
  assert.equal((await s.call("GET", `/api/episodes/${eid}`, undefined, "garbage.jwt")).status, 401);
  assert.equal((await s.call("GET", `/api/episodes/${eid}`, undefined, "other.jwt")).status, 403);
  assert.equal((await s.call("GET", `/api/episodes/${eid}`, undefined, "user.jwt")).status, 403);
  assert.equal((await s.call("GET", `/api/episodes/${eid}`)).status, 200);
});

test("既知の回で説明が NULL なら埋める。埋まった後・説明の無い取り直しでは書かない", async () => {
  const s = setup();
  // 説明の無いフィードで足す（0007 より前に入った回と同じ形）
  s.web.set(FEED, { body: showWithNotes().replace(/<(description|itunes:summary|content:encoded)>[\s\S]*?<\/\1>/g, "") });
  const id = (await s.call("POST", "/api/podcasts", { url: FEED })).json.podcast.id;
  assert.equal(s.count("SELECT COUNT(*) AS n FROM episodes WHERE description IS NULL"), 3);
  const sqls: string[] = [];
  const prepare = s.db.prepare.bind(s.db);
  (s.db as any).prepare = (sql: string) => (sqls.push(sql), prepare(sql));
  const refresh = async () => refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps);
  // 説明が載った → 3回とも埋まる（新しい回は増えない）
  s.web.set(FEED, { body: showWithNotes() });
  assert.deepEqual(await refresh(), { status: "ok", added: 0 });
  assert.deepEqual(plain(s.raw.prepare("SELECT guid, description FROM episodes ORDER BY guid").all()), [
    { guid: "n-1", description: "要約1だけ" },
    { guid: "n-2", description: "<p>説明2<br/>改行</p>" },
    { guid: "n-3", description: '<p>本文3 <a href="https://ex.example/3">リンク</a></p>' },
  ]);
  assert.equal(sqls.filter((q) => /UPDATE[^;]*episodes/i.test(q)).length, 1);
  // 同じ中身の取り直し → 書かない
  sqls.length = 0;
  const before = plain(s.raw.prepare("SELECT * FROM episodes ORDER BY id").all());
  assert.deepEqual(await refresh(), { status: "ok", added: 0 });
  assert.deepEqual(sqls.filter((q) => /^\s*(INSERT|UPDATE)[^;]*episodes/i.test(q)), []);
  // 説明の中身だけ変わった・説明が消えた → 書かない（中身の変化は見ない・埋めた説明は消さない）
  s.web.set(FEED, { body: showWithNotes({ ep3: "<p>書き換え</p>" }) });
  assert.deepEqual(await refresh(), { status: "ok", added: 0 });
  s.web.set(FEED, { body: showWithNotes().replace(/<(description|itunes:summary|content:encoded)>[\s\S]*?<\/\1>/g, "") });
  assert.deepEqual(await refresh(), { status: "ok", added: 0 });
  assert.deepEqual(sqls.filter((q) => /^\s*(INSERT|UPDATE)[^;]*episodes/i.test(q)), []);
  assert.deepEqual(plain(s.raw.prepare("SELECT * FROM episodes ORDER BY id").all()), before);
  // 題名が変わったら書き換える（説明は残る）
  s.web.set(FEED, { body: showWithNotes().replace("<title>第3回</title>", "<title>第3回（改）</title>").replace(/<(description|itunes:summary|content:encoded)>[\s\S]*?<\/\1>/g, "") });
  await refresh();
  assert.deepEqual(plain(s.raw.prepare("SELECT title, description FROM episodes WHERE guid = 'n-3'").get()), {
    title: "第3回（改）",
    description: '<p>本文3 <a href="https://ex.example/3">リンク</a></p>',
  });
});

test("既知の回で説明も中身も変わらない大きい番組は episodes へ書かない（podcastWith は説明なし）", async () => {
  const s = setup();
  s.web.set(FEED, { body: podcastWith(300) });
  const id = (await s.call("POST", "/api/podcasts", { url: FEED })).json.podcast.id;
  const sqls: string[] = [];
  const prepare = s.db.prepare.bind(s.db);
  (s.db as any).prepare = (sql: string) => (sqls.push(sql), prepare(sql));
  assert.deepEqual(await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps), { status: "ok", added: 0 });
  assert.deepEqual(sqls.filter((q) => /^\s*(INSERT|UPDATE)[^;]*episodes/i.test(q)), []);
});

test("移行 SQL 0007: episodes に description を足し、番組の ETag／Last-Modified だけ消す（記事は触らない）。回は残る", () => {
  const all = ["0001_init", "0002_feed_image", "0003_device_tokens", "0004_podcast", "0005_move_podcast_category", "0006_episodes"];
  const { raw } = makeDb(all.map((m) => `migrations/${m}.sql`));
  const t = "2026-11-20T00:00:00.000Z";
  raw.exec(`
    INSERT INTO feeds (id, kind, title, feed_url, etag, last_modified, created_at) VALUES
      (1, 'article', '日記', 'https://a.example/feed', '"a"', 'Mon', '${t}'),
      (2, 'podcast', 'いつまじラジオ', 'https://p1.example/rss', '"p"', 'Tue', '${t}');
    INSERT INTO episodes (id, feed_id, guid, title, fetched_at, sort_at, enclosure_url) VALUES (5, 2, 'g', '#1', '${t}', '${t}', 'https://cdn.example/1.mp3');
  `);
  raw.exec(readFileSync("migrations/0007_episode_description.sql", "utf8"));
  assert.deepEqual(plain(raw.prepare("SELECT id, etag, last_modified FROM feeds ORDER BY id").all()), [
    { id: 1, etag: '"a"', last_modified: "Mon" },
    { id: 2, etag: null, last_modified: null },
  ]);
  assert.deepEqual(plain(raw.prepare("SELECT id, title, description FROM episodes").all()), [{ id: 5, title: "#1", description: null }]);
});
