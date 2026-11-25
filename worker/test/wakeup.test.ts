// 番組の新しい回 → 端末を裏で起こすサイレントプッシュ（background）。alert 通知は alerts=1 の端末だけ
import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, podcastWith } from "./helpers.ts";
import { refreshDue, runScheduled } from "../src/fetcher.ts";
import { apnsHeaders, httpApnsSender, type ApnsEnvironment, type ApnsPushType, type ApnsSender } from "../src/apns.ts";
import { sendNotices, sendWakeups, WAKEUP_PAYLOAD, type Notice } from "../src/notify.ts";

const TOKEN_A = "ab".repeat(32);
const TOKEN_B = "cd".repeat(32);
const TOKEN_C = "ef".repeat(32);
const SHOW = "https://pod.example/feed";

class MockApns implements ApnsSender {
  sent: { token: string; env: ApnsEnvironment; payload: any; type: ApnsPushType }[] = [];
  answer: (token: string) => { status: number; reason?: string } = () => ({ status: 200 });
  async send(token: string, env: ApnsEnvironment, payload: string, type: ApnsPushType = "alert") {
    this.sent.push({ token, env, payload: JSON.parse(payload), type });
    return this.answer(token);
  }
}

/** 番組2本（5回ずつ）と端末3台（B は「通知」オフ） */
async function world(s: ReturnType<typeof setup>) {
  s.web.set(SHOW, { body: podcastWith(5, { prefix: "a", start: "2026-11-18T00:00:00Z" }) });
  s.web.set("https://pod2.example/feed", { body: podcastWith(5, { prefix: "b", start: "2026-11-18T00:00:00Z", title: "二本目" }) });
  assert.equal((await s.call("POST", "/api/podcasts", { url: SHOW })).status, 201);
  assert.equal((await s.call("POST", "/api/podcasts", { url: "https://pod2.example/feed" })).status, 201);
  assert.equal((await s.call("PUT", "/api/devices", { token: TOKEN_A, environment: "development" })).status, 200);
  assert.equal((await s.call("PUT", "/api/devices", { token: TOKEN_B, alerts: false })).status, 200);
  assert.equal((await s.call("PUT", "/api/devices", { token: TOKEN_C, alerts: true })).status, 200);
}

test("番組に新しい回が入った cron: 全端末（「通知」オフも）へ background をちょうど1通ずつ。何本・何回入っても1通", async () => {
  const s = setup({ now: "2026-11-18T03:00:00Z" });
  await world(s);
  const apns = new MockApns();
  s.clock.set("2026-11-19T03:00:00Z");
  // 2本とも新しい回が2つずつ
  s.web.set(SHOW, { body: podcastWith(7, { prefix: "a", start: "2026-11-19T02:00:00Z" }) });
  s.web.set("https://pod2.example/feed", { body: podcastWith(7, { prefix: "b", start: "2026-11-19T02:00:00Z", title: "二本目" }) });
  const r = await runScheduled(s.db, { ...s.deps, push: apns }, 10);
  assert.equal(r.episodes, 4);
  assert.equal(r.woken, 3);
  assert.equal(apns.sent.length, 3);
  assert.deepEqual(apns.sent.map((x) => x.token).sort(), [TOKEN_A, TOKEN_B, TOKEN_C]);
  for (const x of apns.sent) {
    assert.equal(x.type, "background");
    assert.deepEqual(x.payload, { aps: { "content-available": 1 } });
  }
  assert.equal(apns.sent.find((x) => x.token === TOKEN_A)!.env, "development");
});

test("新しい回が無い cron（304・既知の回だけ）では background を送らない", async () => {
  const s = setup({ now: "2026-11-18T03:00:00Z" });
  await world(s);
  const apns = new MockApns();
  s.clock.set("2026-11-19T03:00:00Z");
  s.web.set("https://pod2.example/feed", { status: 304 });
  const r = await refreshDue(s.db, { ...s.deps, push: apns }, 10);
  assert.equal(r.fetched, 2);
  assert.equal(r.episodes, 0);
  assert.equal(r.woken, 0);
  assert.equal(apns.sent.length, 0);
});

test("記事の新着だけの cron では background を送らない（alert は従来どおり別）", async () => {
  const s = setup({ now: "2026-11-18T03:00:00Z" });
  await world(s);
  s.web.set("https://blog.example/feed", { body: podcastWith(0).replace("</channel>", "<item><title>x</title><guid>x1</guid><link>https://blog.example/1</link></item></channel>") });
  assert.equal((await s.call("POST", "/api/feeds", { url: "https://blog.example/feed" })).status, 201);
  s.web.set("https://blog.example/feed", {
    body: podcastWith(0).replace("</channel>", "<item><title>y</title><guid>y1</guid><link>https://blog.example/2</link></item></channel>"),
  });
  s.web.set(SHOW, { status: 304 });
  s.web.set("https://pod2.example/feed", { status: 304 });
  const apns = new MockApns();
  const r = await refreshDue(s.db, { ...s.deps, push: apns }, 10);
  assert.equal(r.added, 1);
  assert.equal(r.woken, 0);
  assert.equal(apns.sent.filter((x) => x.type === "background").length, 0);
});

test("alert のお知らせは alerts=1 の端末だけ。PUT で alerts を切り替えられる・真偽以外は 400", async () => {
  const s = setup();
  await world(s);
  const n: Notice = { item_id: 1, feed_id: 1, feed_title: "a", title: "b", url: null, published_at: "2026-11-18T00:00:00Z" };
  const apns = new MockApns();
  assert.deepEqual(await sendNotices(s.db, [n], apns), { sent: 2, notices: 1 });
  assert.deepEqual(apns.sent.map((x) => [x.token, x.type]).sort(), [
    [TOKEN_A, "alert"],
    [TOKEN_C, "alert"],
  ]);
  // A をオフ・B をオン（省略は true）
  await s.call("PUT", "/api/devices", { token: TOKEN_A, environment: "development", alerts: false });
  await s.call("PUT", "/api/devices", { token: TOKEN_B });
  assert.deepEqual(
    s.raw.prepare("SELECT token, alerts FROM device_tokens ORDER BY token").all().map((r) => ({ ...r })),
    [
      { token: TOKEN_A, alerts: 0 },
      { token: TOKEN_B, alerts: 1 },
      { token: TOKEN_C, alerts: 1 },
    ],
  );
  assert.equal((await s.call("PUT", "/api/devices", { token: TOKEN_A, alerts: "no" })).status, 400);
  assert.equal((await s.call("PUT", "/api/devices", { token: TOKEN_A, alerts: 0 })).status, 400);
});

test("background でも死んだトークンは台帳から消す。鍵が無ければ送らない", async () => {
  const s = setup();
  await world(s);
  assert.equal(await sendWakeups(s.db, null), 0);
  const apns = new MockApns();
  apns.answer = (t) => (t === TOKEN_B ? { status: 410, reason: "Unregistered" } : t === TOKEN_C ? { status: 400, reason: "BadDeviceToken" } : { status: 200 });
  assert.equal(await sendWakeups(s.db, apns), 1);
  assert.deepEqual(s.raw.prepare("SELECT token FROM device_tokens").all().map((r) => r.token), [TOKEN_A]);
});

test("APNs のヘッダ: background は push-type background・priority 5、alert は従来どおり alert・10。topic は bundle id", async () => {
  assert.deepEqual(apnsHeaders("J", "jp.example.app", "background"), {
    authorization: "bearer J",
    "apns-topic": "jp.example.app",
    "apns-push-type": "background",
    "apns-priority": "5",
    "content-type": "application/json",
  });
  assert.equal(apnsHeaders("J", "jp.example.app", "alert")["apns-push-type"], "alert");
  assert.equal(apnsHeaders("J", "jp.example.app", "alert")["apns-priority"], "10");
  // 本物の送り口に通す（fetch を差し替え）。種別を省くと alert
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pkcs8 = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;
  const seen: { url: string; headers: Record<string, string>; body: string }[] = [];
  const sender = httpApnsSender({ key: pem, keyId: "K", teamId: "T", bundleId: "jp.example.app" }, async (url, init) => {
    seen.push({ url, headers: init.headers as Record<string, string>, body: String(init.body) });
    return new Response(null, { status: 200 });
  });
  await sender.send(TOKEN_A, "development", WAKEUP_PAYLOAD, "background");
  await sender.send(TOKEN_A, "production", "{}");
  assert.equal(seen[0].url, `https://api.sandbox.push.apple.com/3/device/${TOKEN_A}`);
  assert.equal(seen[0].headers["apns-push-type"], "background");
  assert.equal(seen[0].headers["apns-priority"], "5");
  assert.equal(seen[0].body, '{"aps":{"content-available":1}}');
  assert.equal(seen[1].headers["apns-push-type"], "alert");
  assert.equal(seen[1].headers["apns-priority"], "10");
});
