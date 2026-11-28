// 段階4の小さな試し: ボットから X・Instagram の投稿を受け取る口（REST・MCP）。設計の受け入れ条件（試し）1〜3
import { test } from "node:test";
import assert from "node:assert/strict";
import { setup } from "./helpers.ts";
import { purgeOld } from "../src/store.ts";

function post(n: number, o: Record<string, unknown> = {}) {
  return {
    platform: "x",
    post_id: `18620000000000000${n}`,
    url: `https://x.com/someone/status/18620000000000000${n}`,
    author_name: "だれか",
    author_handle: "@someone",
    author_avatar_url: "https://pbs.twimg.com/profile_images/1/a.jpg",
    text: `  本文 ${n}\n改行も　全角空白も そのまま 🙂  `,
    media: [{ type: "image", url: `https://pbs.twimg.com/media/${n}.jpg` }],
    posted_at: `2026-11-2${n}T09:30:00+09:00`,
    like_count: 10 + n,
    repost_count: 2,
    reply_count: null,
    quoted: n === 1 ? { post_id: "1", url: "https://x.com/other/status/1", author_handle: "other", text: "引用元" } : undefined,
    source: "grok-bot",
    ...o,
  };
}

// ---------------- 1. REST で入り、二度目は重複として飛ばされる ----------------

test("POST /api/social/posts: 入る・同じものをもう一度送ると skipped・本文は改変しない", async () => {
  const s = setup({ now: "2026-11-29T03:00:00Z" });
  let r = await s.call("POST", "/api/social/posts", [post(1), post(2)]);
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { inserted: 2, skipped: 0, rejected: [] });
  r = await s.call("POST", "/api/social/posts", [post(1), post(2), post(3)]);
  assert.deepEqual(r.json, { inserted: 1, skipped: 2, rejected: [] });
  assert.equal(s.count("SELECT COUNT(*) AS n FROM social_posts"), 3);
  // { posts: [...] } の形も受ける・同じ要求の中の重複も飛ばす
  r = await s.call("POST", "/api/social/posts", { posts: [post(4), post(4)] });
  assert.deepEqual(r.json, { inserted: 1, skipped: 1, rejected: [] });

  const list = (await s.call("GET", "/api/social/posts?platform=x")).json;
  assert.deepEqual(list.posts.map((p: any) => p.post_id), ["186200000000000004", "186200000000000003", "186200000000000002", "186200000000000001"]);
  const p1 = list.posts[3];
  assert.equal(p1.text, post(1).text); // trim も改行の直しもしない
  assert.equal(p1.author_handle, "someone"); // @ だけ落とす
  assert.equal(p1.posted_at, "2026-11-21T00:30:00.000Z"); // UTC にそろえる
  assert.deepEqual(p1.media, [{ type: "image", url: "https://pbs.twimg.com/media/1.jpg" }]);
  assert.equal(p1.quoted.text, "引用元");
  assert.equal(p1.like_count, 11);
  assert.equal(p1.reply_count, null);
  assert.equal(p1.view_count, null);
  assert.equal(p1.source, "grok-bot");
  assert.equal(p1.fetched_at, "2026-11-29T03:00:00.000Z");
  assert.equal(p1.read_at, null);
  assert.equal(list.posts[2].quoted, null);
  assert.equal(list.next, null);
});

test("不正な行だけ理由つきで弾き、正しい行は入れる", async () => {
  const s = setup();
  const r = await s.call("POST", "/api/social/posts", [
    post(1),
    post(2, { platform: "threads" }),
    post(3, { post_id: 186200000000000003 }), // 数字は桁が落ちるので文字列だけ
    post(4, { url: "https://example.com/someone/status/1" }),
    post(5, { posted_at: "2026-11-25" }),
    post(6, { text: undefined }),
    post(7, { media: [{ type: "audio", url: "https://a.example/x.mp3" }] }),
    post(8, { like_count: -1 }),
    "文字列",
    post(9, { platform: "instagram", post_id: "DAbc_12-x", url: "https://www.instagram.com/p/DAbc_12-x/", text: "" }),
  ]);
  assert.equal(r.status, 200);
  assert.equal(r.json.inserted, 2);
  assert.equal(r.json.skipped, 0);
  assert.deepEqual(r.json.rejected.map((x: any) => x.index), [1, 2, 3, 4, 5, 6, 7, 8]);
  for (const x of r.json.rejected) assert.equal(typeof x.reason, "string");
  assert.match(r.json.rejected[0].reason, /platform/);
  assert.match(r.json.rejected[3].reason, /posted_at/);
  assert.match(r.json.rejected[4].reason, /text/);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM social_posts"), 2);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM social_posts WHERE platform = 'instagram' AND source = 'grok-bot'"), 1);
});

test("配列でない・51件以上は 400 で何も入れない", async () => {
  const s = setup();
  assert.equal((await s.call("POST", "/api/social/posts", { nope: 1 })).json.error, "bad_posts");
  assert.equal((await s.call("POST", "/api/social/posts", "not json")).status, 400);
  const many = Array.from({ length: 51 }, (_, i) => post(1, { post_id: `9${i}`, url: `https://x.com/a/status/9${i}` }));
  const r = await s.call("POST", "/api/social/posts", many);
  assert.equal(r.status, 400);
  assert.equal(r.json.error, "too_many_posts");
  assert.equal(s.count("SELECT COUNT(*) AS n FROM social_posts"), 0);
  // 50件ちょうどは入る・source を省けば "api"
  const fifty = many.slice(0, 50).map((p) => ({ ...p, source: undefined }));
  assert.equal((await s.call("POST", "/api/social/posts", fifty)).json.inserted, 50);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM social_posts WHERE source = 'api'"), 50);
});

test("GET /api/social/posts: platform で絞る・before と next で続き・limit", async () => {
  const s = setup();
  await s.call("POST", "/api/social/posts", [
    post(1),
    post(2),
    post(3),
    post(4, { platform: "instagram", post_id: "C1", url: "https://instagram.com/p/C1/" }),
  ]);
  let r = await s.call("GET", "/api/social/posts?limit=2");
  assert.deepEqual(r.json.posts.map((p: any) => p.post_id), ["C1", "186200000000000003"]);
  assert.ok(r.json.next);
  r = await s.call("GET", `/api/social/posts?limit=2&before=${encodeURIComponent(r.json.next)}`);
  assert.deepEqual(r.json.posts.map((p: any) => p.post_id), ["186200000000000002", "186200000000000001"]);
  r = await s.call("GET", `/api/social/posts?platform=x&before=${encodeURIComponent("2026-11-23T00:30:00Z")}`);
  assert.deepEqual(r.json.posts.map((p: any) => p.post_id), ["186200000000000002", "186200000000000001"]);
  assert.equal((await s.call("GET", "/api/social/posts?platform=instagram")).json.posts.length, 1);
  assert.equal((await s.call("GET", "/api/social/posts?platform=threads")).status, 400);
  assert.equal((await s.call("GET", "/api/social/posts?before=yesterday")).status, 400);
  assert.equal((await s.call("GET", "/api/social/posts?limit=0")).status, 400);
});

test("GET /api/social/known: since 以降の post_id（新しい順）・省けば直近7日・platform は必須", async () => {
  const s = setup({ now: "2026-11-29T00:00:00Z" });
  await s.call("POST", "/api/social/posts", [post(1), post(2), post(3), post(4, { platform: "instagram", post_id: "C1", url: "https://instagram.com/p/C1/" })]);
  let r = await s.call("GET", `/api/social/known?platform=x&since=${encodeURIComponent("2026-11-22T00:00:00Z")}`);
  assert.deepEqual(r.json, { platform: "x", since: "2026-11-22T00:00:00.000Z", post_ids: ["186200000000000003", "186200000000000002"] });
  r = await s.call("GET", "/api/social/known?platform=x");
  assert.equal(r.json.since, "2026-11-22T00:00:00.000Z");
  assert.equal(r.json.post_ids.length, 2);
  assert.deepEqual((await s.call("GET", "/api/social/known?platform=instagram&since=2026-11-01T00:00:00Z")).json.post_ids, ["C1"]);
  assert.equal((await s.call("GET", "/api/social/known")).status, 400);
  assert.equal((await s.call("GET", "/api/social/known?platform=x&since=2026-11-01")).status, 400);
});

test("90日の掃除: 既読の投稿だけ消す・未読は残す", async () => {
  const s = setup({ now: "2026-11-29T00:00:00Z" });
  await s.call("POST", "/api/social/posts", [post(1), post(2), post(3)]);
  s.raw.prepare("UPDATE social_posts SET read_at = '2026-08-01T00:00:00.000Z' WHERE post_id = ?").run("186200000000000001");
  s.raw.prepare("UPDATE social_posts SET read_at = '2026-11-01T00:00:00.000Z' WHERE post_id = ?").run("186200000000000002");
  await purgeOld(s.db, s.clock.now());
  const left = (s.raw.prepare("SELECT post_id FROM social_posts ORDER BY post_id").all() as { post_id: string }[]).map((r) => r.post_id);
  assert.deepEqual(left, ["186200000000000002", "186200000000000003"]);
});

// ---------------- 2. MCP: initialize → tools/list → tools/call(add_posts) で D1 に入る ----------------

/** id が null なら通知（id なし） */
async function rpc(s: ReturnType<typeof setup>, method: string, params?: unknown, id: number | string | null = 1, token: string | null = "ok.jwt") {
  const msg: Record<string, unknown> = { jsonrpc: "2.0", method };
  if (id !== null) msg.id = id;
  if (params !== undefined) msg.params = params;
  return s.request("POST", "/api/mcp", msg, token, { Accept: "application/json, text/event-stream" });
}

test("MCP: initialize → notifications/initialized → tools/list → tools/call(add_posts) で D1 に入る", async () => {
  const s = setup({ now: "2026-11-29T03:00:00Z" });
  let res = await rpc(s, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "grok-bot", version: "1" } });
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type") ?? "", /^application\/json/);
  const init = (await res.json()) as any;
  assert.equal(init.jsonrpc, "2.0");
  assert.equal(init.id, 1);
  assert.equal(init.result.protocolVersion, "2025-06-18");
  assert.deepEqual(init.result.serverInfo.name, "tayori");
  assert.ok(init.result.capabilities.tools);

  res = await rpc(s, "notifications/initialized", undefined, null);
  assert.equal(res.status, 202);
  assert.equal(await res.text(), "");

  res = await rpc(s, "tools/list", {}, 2);
  const list = (await res.json()) as any;
  assert.deepEqual(list.result.tools.map((t: any) => t.name), ["add_posts", "list_known_post_ids"]);
  const add = list.result.tools[0];
  assert.equal(add.inputSchema.type, "object");
  assert.deepEqual(add.inputSchema.required, ["posts"]);
  assert.equal(add.inputSchema.properties.posts.maxItems, 50);
  assert.deepEqual(add.inputSchema.properties.posts.items.properties.platform.enum, ["x", "instagram"]);
  for (const w of ["本文は改変しない", "正規 URL", "ISO 8601"]) assert.ok(add.description.includes(w), w);

  res = await rpc(s, "tools/call", { name: "add_posts", arguments: { posts: [post(1), post(2)] } }, 3);
  let call = (await res.json()) as any;
  assert.equal(call.id, 3);
  assert.equal(call.result.isError, false);
  assert.equal(call.result.content[0].type, "text");
  assert.deepEqual(JSON.parse(call.result.content[0].text), { inserted: 2, skipped: 0, rejected: [] });
  assert.equal(s.count("SELECT COUNT(*) AS n FROM social_posts"), 2);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM social_posts WHERE source = 'grok-bot'"), 2);

  // 送り直しは skipped・known に出る
  res = await rpc(s, "tools/call", { name: "add_posts", arguments: { posts: [post(1, { source: undefined }), post(3, { source: undefined })] } }, 4);
  call = (await res.json()) as any;
  assert.deepEqual(JSON.parse(call.result.content[0].text), { inserted: 1, skipped: 1, rejected: [] });
  assert.equal(s.count("SELECT COUNT(*) AS n FROM social_posts WHERE source = 'mcp'"), 1);
  res = await rpc(s, "tools/call", { name: "list_known_post_ids", arguments: { platform: "x", since: "2026-11-01T00:00:00Z" } }, 5);
  call = (await res.json()) as any;
  assert.equal(call.result.isError, false);
  assert.deepEqual(JSON.parse(call.result.content[0].text).post_ids, ["186200000000000003", "186200000000000002", "186200000000000001"]);
});

test("MCP: 不正入力は isError・知らないツール／メソッドは JSON-RPC のエラー・ping", async () => {
  const s = setup();
  const body = async (r: Response) => (await r.json()) as any;
  let j = await body(await rpc(s, "tools/call", { name: "add_posts", arguments: { posts: "nope" } }));
  assert.equal(j.result.isError, true);
  assert.equal(JSON.parse(j.result.content[0].text).error, "bad_posts");
  j = await body(await rpc(s, "tools/call", { name: "add_posts", arguments: { posts: [post(1), post(2, { posted_at: "きのう" })] } }));
  assert.equal(j.result.isError, true); // 弾いた行がある
  assert.deepEqual(JSON.parse(j.result.content[0].text).inserted, 1);
  assert.deepEqual(JSON.parse(j.result.content[0].text).rejected.map((x: any) => x.index), [1]);
  j = await body(await rpc(s, "tools/call", { name: "add_posts", arguments: { posts: Array(51).fill(post(1)) } }));
  assert.equal(JSON.parse(j.result.content[0].text).error, "too_many_posts");
  j = await body(await rpc(s, "tools/call", { name: "list_known_post_ids", arguments: { platform: "threads" } }));
  assert.equal(j.result.isError, true);
  j = await body(await rpc(s, "tools/call", { name: "list_known_post_ids", arguments: {} }));
  assert.equal(j.result.isError, true);
  j = await body(await rpc(s, "tools/call", { name: "delete_everything", arguments: {} }));
  assert.equal(j.error.code, -32602);
  j = await body(await rpc(s, "resources/list", {}));
  assert.equal(j.error.code, -32601);
  j = await body(await rpc(s, "ping", undefined, "p1"));
  assert.deepEqual(j, { jsonrpc: "2.0", id: "p1", result: {} });
  // 知らない版は 2025-06-18
  j = await body(await rpc(s, "initialize", { protocolVersion: "1999-01-01", capabilities: {}, clientInfo: { name: "x", version: "1" } }));
  assert.equal(j.result.protocolVersion, "2025-06-18");
  // 壊れた JSON は -32700・配列（バッチ）は受けない
  let r = await s.request("POST", "/api/mcp", "{oops");
  assert.equal(r.status, 400);
  assert.equal(((await r.json()) as any).error.code, -32700);
  r = await s.request("POST", "/api/mcp", [{ jsonrpc: "2.0", id: 1, method: "ping" }]);
  assert.equal(((await r.json()) as any).error.code, -32600);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM social_posts"), 1);
});

test("MCP: GET・DELETE /api/mcp は 405", async () => {
  const s = setup();
  for (const m of ["GET", "DELETE"]) {
    const r = await s.request(m, "/api/mcp");
    assert.equal(r.status, 405, m);
    assert.equal(r.headers.get("allow"), "POST");
  }
});

// ---------------- 3. Access のヘッダが無いと 401（MCP も） ----------------

test("トークンが無ければ投稿の口も MCP も 401・書き込まない／許可外は 403", async () => {
  const s = setup();
  const cases: [string, string, unknown?][] = [
    ["POST", "/api/social/posts", [post(1)]],
    ["GET", "/api/social/posts"],
    ["GET", "/api/social/known?platform=x"],
    ["POST", "/api/mcp", { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } }],
    ["POST", "/api/mcp", { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "add_posts", arguments: { posts: [post(1)] } } }],
    ["GET", "/api/mcp"],
  ];
  for (const [m, p, b] of cases) {
    const r = await s.call(m, p, b, null);
    assert.equal(r.status, 401, `${m} ${p}`);
    assert.deepEqual(r.json, { error: "unauthorized" });
    assert.equal((await s.call(m, p, b, "other.jwt")).status, 403, `${m} ${p}`);
  }
  assert.equal(s.count("SELECT COUNT(*) AS n FROM social_posts"), 0);
});
