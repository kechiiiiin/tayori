// 受け入れ条件2・3: RSS 2.0・Atom・JSON Feed（と RSS 1.0）を読む。HTML からフィードの候補を拾う
import { test } from "node:test";
import assert from "node:assert/strict";
import { fixture } from "./helpers.ts";
import { parseFeed, newest, toIso } from "../src/parse.ts";
import { findFeedLinks } from "../src/discover.ts";

test("RSS 2.0: 題名・リンク（相対は解く）・guid（無ければ URL）・日付", () => {
  const f = parseFeed(fixture("rss2.xml"), "https://anikuma.example/feed")!;
  assert.equal(f.kind, "rss");
  assert.equal(f.title, "アニクマ");
  assert.equal(f.site_url, "https://anikuma.example/");
  assert.deepEqual(f.items, [
    { guid: "post-3", url: "https://anikuma.example/posts/3", title: "1on1 を「報告会」にしないための三つの問い", published_at: "2026-11-17T20:00:00.000Z" },
    { guid: "https://anikuma.example/posts/2", url: "https://anikuma.example/posts/2", title: '設計レビューで "決めない" を決める', published_at: "2026-11-17T12:00:00.000Z" },
    { guid: "https://anikuma.example/posts/1", url: null, title: "日付の無い記事", published_at: null },
  ]);
});

test("Atom: rel=alternate のリンク・type=html の題名からタグを落とす・published が無ければ updated", () => {
  const f = parseFeed(fixture("atom.xml"), "https://zenn.example/topics/architecture/feed")!;
  assert.equal(f.kind, "atom");
  assert.equal(f.title, "Zenn architecture");
  assert.equal(f.site_url, "https://zenn.example/topics/architecture");
  assert.deepEqual(f.items, [
    { guid: "tag:zenn.example,2026:a1", url: "https://zenn.example/a/1", title: "AI エージェントに任せる仕事、任せない仕事", published_at: "2026-11-17T00:00:00.000Z" },
    { guid: "tag:zenn.example,2026:a2", url: "https://zenn.example/topics/architecture/a/2", title: "薬局の待ち時間をどう測るか", published_at: "2026-11-16T09:00:00.000Z" },
  ]);
});

test("JSON Feed: id（数値も）・題名が無ければ本文の頭", () => {
  const f = parseFeed(fixture("feed.json"), "https://blog.example.jp/feed.json")!;
  assert.equal(f.kind, "json");
  assert.equal(f.title, "ある人のブログ");
  assert.equal(f.site_url, "https://blog.example.jp/");
  assert.deepEqual(
    f.items.map((i) => [i.guid, i.title, i.published_at]),
    [
      ["launcher", "週末に作った小さなランチャーのこと", "2026-11-15T01:00:00.000Z"],
      ["42", "題名の無い短い投稿の本文", "2026-11-14T01:00:00.000Z"],
    ],
  );
});

test("RSS 1.0（RDF）: rdf:about を guid に・dc:date", () => {
  const f = parseFeed(fixture("rdf.xml"), "https://diary.example/index.rdf")!;
  assert.equal(f.kind, "rdf");
  assert.equal(f.title, "ある人の日記");
  assert.deepEqual(f.items, [
    { guid: "https://diary.example/2026/11/17", url: "https://diary.example/2026/11/17", title: "山小屋の朝ごはんが好きだという話", published_at: "2026-11-16T23:00:00.000Z" },
  ]);
});

test("フィードでないもの（HTML・壊れた JSON・ただの文字）は null", () => {
  assert.equal(parseFeed(fixture("site.html"), "https://blog.example.jp/"), null);
  assert.equal(parseFeed("{ not json", "https://x.example/"), null);
  assert.equal(parseFeed('{"title":"x","items":[]}', "https://x.example/"), null);
  assert.equal(parseFeed("hello", "https://x.example/"), null);
});

test("日付: RFC 822・ISO・タイムゾーンの無い「年-月-日 時:分」（JST とみなす）", () => {
  assert.equal(toIso("Wed, 18 Nov 2026 05:00:00 +0900"), "2026-11-17T20:00:00.000Z");
  assert.equal(toIso("2026-11-18T05:00:00Z"), "2026-11-18T05:00:00.000Z");
  assert.equal(toIso("2026/11/18 09:30"), "2026-11-18T00:30:00.000Z");
  assert.equal(toIso("そのうち"), null);
});

test("newest: 日付があれば新しい順、無いものが混じればフィードの並び", () => {
  const a = { guid: "a", url: null, title: "a", published_at: "2026-11-01T00:00:00.000Z" };
  const b = { guid: "b", url: null, title: "b", published_at: "2026-11-03T00:00:00.000Z" };
  const c = { guid: "c", url: null, title: "c", published_at: null };
  assert.deepEqual(newest([a, b], 1).map((i) => i.guid), ["b"]);
  assert.deepEqual(newest([a, c, b], 2).map((i) => i.guid), ["a", "c"]);
});

test("探索: <link rel=alternate> を書いてある順に・コメントは後ろ・コメントアウトは無視・&amp; を戻す", () => {
  assert.deepEqual(findFeedLinks(fixture("site.html"), "https://blog.example.jp/"), [
    "https://blog.example.jp/feed.xml?a=1&b=2",
    "https://blog.example.jp/atom.xml",
    "https://blog.example.jp/comments/feed/",
  ]);
  assert.deepEqual(findFeedLinks("<html><head><title>x</title></head></html>", "https://x.example/"), []);
});

test("探索: <base href> があればそこから解く", () => {
  const html = '<head><base href="https://cdn.example/blog/"><link rel="alternate" type="application/atom+xml" href="atom.xml"></head>';
  assert.deepEqual(findFeedLinks(html, "https://x.example/"), ["https://cdn.example/blog/atom.xml"]);
});
