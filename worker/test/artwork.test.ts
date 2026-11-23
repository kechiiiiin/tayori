// ポッドキャストの番組アートワーク（チャンネルの itunes:image@href）を feeds.image_url に持ち、取得のたびに更新する
import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, fixture } from "./helpers.ts";
import { parseFeed } from "../src/parse.ts";
import { refreshFeed } from "../src/fetcher.ts";
import { getFeedRow } from "../src/store.ts";

const FEED = "https://podcast.example/feed.xml";
const NO_ART = (s: string) => s.replace('<itunes:image href="/art/show-3000.jpg"/>', "");

test("parse: チャンネルの itunes:image を拾う（相対は解く・回ごとの画像とブログの <image> は使わない）", () => {
  const f = parseFeed(fixture("podcast.xml"), FEED)!;
  assert.equal(f.image_url, "https://podcast.example/art/show-3000.jpg");
});

test("parse: itunes:image が無いフィードは null（<image> があっても）", () => {
  assert.equal(parseFeed(NO_ART(fixture("podcast.xml")), FEED)!.image_url, null);
  assert.equal(parseFeed(fixture("rss2.xml"), "https://anikuma.example/feed")!.image_url, null);
  assert.equal(parseFeed(fixture("atom.xml"), "https://blog.example.jp/atom.xml")!.image_url, null);
});

test("足したとき API の feed に image_url が載り、取得のたびに入れ替わる。304 と失敗では消えない", async () => {
  const s = setup();
  s.web.set(FEED, { body: fixture("podcast.xml"), etag: '"v1"' });
  const r = await s.call("POST", "/api/feeds", { url: FEED });
  assert.equal(r.status, 201);
  assert.equal(r.json.feed.image_url, "https://podcast.example/art/show-3000.jpg");
  const id = r.json.feed.id as number;
  const art = async () => (await getFeedRow(s.db, id))!.image_url;

  // 304: そのまま
  await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps);
  assert.equal(await art(), "https://podcast.example/art/show-3000.jpg");

  // 失敗: そのまま
  s.web.set(FEED, { status: 503 });
  await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps);
  assert.equal(await art(), "https://podcast.example/art/show-3000.jpg");

  // アートワークが変わった
  s.web.set(FEED, { body: fixture("podcast.xml").replace("show-3000.jpg", "show-2026.jpg") });
  await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps);
  const list = (await s.call("GET", "/api/feeds")).json.feeds;
  assert.equal(list[0].image_url, "https://podcast.example/art/show-2026.jpg");

  // itunes:image が消えた → null
  s.web.set(FEED, { body: NO_ART(fixture("podcast.xml")) });
  await refreshFeed(s.db, (await getFeedRow(s.db, id))!, s.deps);
  assert.equal(await art(), null);
});
