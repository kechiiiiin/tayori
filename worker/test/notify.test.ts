// 「メイン」の新着のプッシュ: メインのサイトだけ・取得で新しく入った直近の記事だけ・1サイト3通まで・古い記事は鳴らさない
import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, rssWith } from "./helpers.ts";
import { refreshDue, refreshFeed, runScheduled } from "../src/fetcher.ts";
import { getFeedRow } from "../src/store.ts";
import type { ApnsEnvironment, ApnsSender } from "../src/apns.ts";
import { NOTIFY_MAX_PER_FEED, sendNotices, type Notice } from "../src/notify.ts";
import { b64url, importP8, makeProviderToken } from "../src/apns.ts";

const TOKEN_A = "ab".repeat(32);
const TOKEN_B = "cd".repeat(32);

class MockApns implements ApnsSender {
  sent: { token: string; env: ApnsEnvironment; payload: any }[] = [];
  answer: (token: string) => { status: number; reason?: string } = () => ({ status: 200 });
  async send(token: string, env: ApnsEnvironment, payload: string) {
    this.sent.push({ token, env, payload: JSON.parse(payload) });
    return this.answer(token);
  }
}

/** n 件の RSS（start から 1時間ずつ古くなる） */
function hourly(n: number, prefix: string, start: string, title = "サイト") {
  const t0 = Date.parse(start);
  const items = Array.from({ length: n }, (_, i) => {
    const d = new Date(t0 - i * 3600_000).toUTCString();
    return `<item><title>${prefix} 記事 ${i + 1}</title><link>https://${prefix}.example/${i + 1}</link><guid>${prefix}-${i + 1}</guid><pubDate>${d}</pubDate></item>`;
  }).join("\n");
  return `<?xml version="1.0"?><rss version="2.0"><channel><title>${title}</title><link>https://${prefix}.example/</link>${items}</channel></rss>`;
}

/** メイン・その他のカテゴリと、それぞれにサイトを1つ。端末を1台登録 */
async function world(s: ReturnType<typeof setup>) {
  const other = (await s.call("POST", "/api/categories", { name: "ポッドキャスト" })).json.category.id;
  const main = (await s.call("POST", "/api/categories", { name: "メイン" })).json.category.id;
  // 足した時点の記事（初回取り込み）は鳴らない
  s.web.set("https://m.example/feed", { body: hourly(2, "m-old", "2026-11-18T02:00:00Z", "メインのサイト") });
  s.web.set("https://o.example/feed", { body: hourly(2, "o-old", "2026-11-18T02:00:00Z", "ほかのサイト") });
  const m = (await s.call("POST", "/api/feeds", { url: "https://m.example/feed", category_id: main })).json.feed.id as number;
  const o = (await s.call("POST", "/api/feeds", { url: "https://o.example/feed", category_id: other })).json.feed.id as number;
  assert.equal((await s.call("PUT", "/api/devices", { token: TOKEN_A.toUpperCase(), environment: "development" })).status, 200);
  return { main, other, m, o };
}

test("メインのサイトの新着だけ、サイト名＋題名で1記事1通。タップ用に item_id を載せる。初回取り込みは鳴らない", async () => {
  const s = setup({ now: "2026-11-18T03:00:00Z" });
  const { m } = await world(s);
  const apns = new MockApns();
  s.clock.set("2026-11-18T04:00:00Z");
  s.web.set("https://m.example/feed", { body: hourly(1, "m-new", "2026-11-18T03:30:00Z", "メインのサイト") + "" });
  s.web.set("https://o.example/feed", { body: hourly(1, "o-new", "2026-11-18T03:30:00Z", "ほかのサイト") });
  const r = await refreshDue(s.db, { ...s.deps, push: apns }, 10);
  assert.equal(r.added, 2);
  assert.equal(r.notices, 1);
  assert.equal(apns.sent.length, 1);
  const p = apns.sent[0];
  assert.equal(p.token, TOKEN_A);
  assert.equal(p.env, "development");
  assert.deepEqual(p.payload.aps.alert, { title: "メインのサイト", body: "m-new 記事 1" });
  const id = Number((s.raw.prepare("SELECT id FROM items WHERE guid = 'm-new-1'").get() as { id: number }).id);
  assert.equal(p.payload.item_id, id);
  assert.equal(p.payload.url, "https://m-new.example/1");
  // 記事1件を API で取れる（通知のタップで開く）
  const got = await s.call("GET", `/api/items/${id}`);
  assert.equal(got.json.item.feed_id, m);
  assert.equal(got.json.item.title, "m-new 記事 1");
});

test("1回の取得で同じサイトから多数 → 新しい順に3通まで。24時間より古い記事・日付の無い記事は鳴らない", async () => {
  const s = setup({ now: "2026-11-18T03:00:00Z" });
  const { m } = await world(s);
  const apns = new MockApns();
  s.clock.set("2026-11-20T00:00:00Z");
  // 新着 30 件（1時間ずつ古い・最初の 24 件だけが 24 時間以内）＋日付の無い記事
  const body = hourly(30, "burst", "2026-11-19T23:30:00Z", "メインのサイト").replace(
    "</channel>",
    "<item><title>日付なし</title><guid>nodate</guid><link>https://burst.example/x</link></item></channel>",
  );
  s.web.set("https://m.example/feed", { body });
  s.web.set("https://o.example/feed", { status: 304 });
  const notices: Notice[] = [];
  const r = await refreshFeed(s.db, (await getFeedRow(s.db, m))!, s.deps, notices);
  assert.equal(r.added, 31);
  assert.equal(notices.length, NOTIFY_MAX_PER_FEED);
  assert.deepEqual(notices.map((n) => n.title), ["burst 記事 1", "burst 記事 2", "burst 記事 3"]);
  await sendNotices(s.db, notices, apns);
  assert.equal(apns.sent.length, 3);
});

test("古い記事の一括取り込み（published が 24 時間より前）は鳴らない", async () => {
  const s = setup({ now: "2026-11-18T03:00:00Z" });
  await world(s);
  const apns = new MockApns();
  s.clock.set("2026-11-25T00:00:00Z");
  // 過去の回をまとめて出し直した（どれも数日前）
  s.web.set("https://m.example/feed", { body: rssWith(10, { prefix: "back", start: "2026-11-23T00:00:00Z" }) });
  s.web.set("https://o.example/feed", { status: 304 });
  const r = await runScheduled(s.db, { ...s.deps, push: apns }, 10);
  assert.equal(r.added, 10);
  assert.equal(r.notices, 0);
  assert.equal(apns.sent.length, 0);
});

test("カテゴリの名前が「メイン」でなくなれば鳴らない", async () => {
  const s = setup({ now: "2026-11-18T03:00:00Z" });
  const { main } = await world(s);
  await s.call("PATCH", `/api/categories/${main}`, { name: "メイン2" });
  const apns = new MockApns();
  s.clock.set("2026-11-18T04:00:00Z");
  s.web.set("https://m.example/feed", { body: hourly(1, "m-new", "2026-11-18T03:30:00Z") });
  s.web.set("https://o.example/feed", { status: 304 });
  await refreshDue(s.db, { ...s.deps, push: apns }, 10);
  assert.equal(apns.sent.length, 0);
});

test("端末: 登録・環境の上書き・解除。死んだトークンは台帳から消す。鍵が無ければ送らない", async () => {
  const s = setup();
  assert.equal((await s.call("PUT", "/api/devices", { token: "zz" })).status, 400);
  assert.equal((await s.call("PUT", "/api/devices", { token: TOKEN_A, environment: "staging" })).status, 400);
  assert.equal((await s.call("PUT", "/api/devices", { token: TOKEN_A }, null)).status, 401);
  await s.call("PUT", "/api/devices", { token: TOKEN_A, environment: "development" });
  await s.call("PUT", "/api/devices", { token: TOKEN_A, environment: "production" });
  await s.call("PUT", "/api/devices", { token: TOKEN_B });
  assert.deepEqual(s.raw.prepare("SELECT token, environment FROM device_tokens ORDER BY token").all().map((r) => ({ ...r })), [
    { token: TOKEN_A, environment: "production" },
    { token: TOKEN_B, environment: "production" },
  ]);
  const n: Notice = { item_id: 1, feed_id: 1, feed_title: "a", title: "b", url: null, published_at: "2026-11-18T00:00:00Z" };
  assert.deepEqual(await sendNotices(s.db, [n], null), { sent: 0, notices: 1 });
  const apns = new MockApns();
  apns.answer = (t) => (t === TOKEN_B ? { status: 410, reason: "Unregistered" } : { status: 200 });
  assert.deepEqual(await sendNotices(s.db, [n, n], apns), { sent: 2, notices: 2 });
  assert.equal(apns.sent.filter((x) => x.token === TOKEN_B).length, 1); // 死んだら2通目は送らない
  assert.equal(s.count("SELECT COUNT(*) AS n FROM device_tokens"), 1);
  assert.equal((await s.call("DELETE", `/api/devices/${TOKEN_A}`)).status, 200);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM device_tokens"), 0);
});

test("APNs の JWT: ES256 で署名し、公開鍵で検証できる（家族掲示板と同じ作り）", async () => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pkcs8 = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;
  const jwt = await makeProviderToken(await importP8(pem), "KEYID12345", "TEAMID1234", 1_800_000_000);
  const [h, c, sig] = jwt.split(".");
  assert.deepEqual(JSON.parse(atob(h.replace(/-/g, "+").replace(/_/g, "/"))), { alg: "ES256", kid: "KEYID12345" });
  assert.deepEqual(JSON.parse(atob(c.replace(/-/g, "+").replace(/_/g, "/"))), { iss: "TEAMID1234", iat: 1_800_000_000 });
  const raw = Uint8Array.from(atob(sig.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (sig.length % 4)) % 4)), (x) => x.charCodeAt(0));
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, raw, new TextEncoder().encode(`${h}.${c}`));
  assert.equal(ok, true);
  assert.equal(b64url("a"), "YQ");
});
