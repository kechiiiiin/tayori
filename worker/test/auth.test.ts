// 受け入れ条件1: サービストークンなし・許可外は 401／403。拒んだ要求では書き込まない
import { test } from "node:test";
import assert from "node:assert/strict";
import { setup } from "./helpers.ts";
import type { Sekisho } from "../src/auth.ts";

const ROUTES: [string, string, unknown?][] = [
  ["GET", "/api/items"],
  ["POST", "/api/items/1/read"],
  ["DELETE", "/api/items/1/read"],
  ["PUT", "/api/items/1/comment", { comment: "x" }],
  ["GET", "/api/categories"],
  ["POST", "/api/categories", { name: "仕事" }],
  ["PATCH", "/api/categories/1", { name: "x" }],
  ["DELETE", "/api/categories/1"],
  ["GET", "/api/feeds"],
  ["POST", "/api/feeds", { url: "https://anikuma.example/" }],
  ["PATCH", "/api/feeds/1", { category_id: null }],
  ["DELETE", "/api/feeds/1"],
  ["POST", "/api/feeds/1/refresh"],
];

test("トークンが無ければ全部の API が 401", async () => {
  const s = setup();
  for (const [m, p, b] of ROUTES) {
    const r = await s.call(m, p, b, null);
    assert.equal(r.status, 401, `${m} ${p}`);
    assert.deepEqual(r.json, { error: "unauthorized" });
  }
});

test("関所が否認したトークンは 401", async () => {
  const s = setup();
  for (const [m, p, b] of ROUTES) assert.equal((await s.call(m, p, b, "garbage.jwt")).status, 401, `${m} ${p}`);
});

test("許可外の Client ID・ブラウザのユーザーは 403", async () => {
  const s = setup();
  for (const [m, p, b] of ROUTES) assert.equal((await s.call(m, p, b, "other.jwt")).status, 403, `${m} ${p}`);
  assert.equal((await s.call("GET", "/api/items", undefined, "user.jwt")).status, 403);
});

test("ACCESS_SERVICE_CLIENT_IDS が空なら 403（1本も通さない）", async () => {
  assert.equal((await setup({ env: { ACCESS_SERVICE_CLIENT_IDS: "" } }).call("GET", "/api/items")).status, 403);
});

test("許可された Client ID は通る（大小を無視）", async () => {
  assert.equal((await setup().call("GET", "/api/items")).status, 200);
});

test("設定漏れ・関所の故障は 401（fail-closed）", async () => {
  assert.equal((await setup({ env: { CF_ACCESS_AUD: "" } }).call("GET", "/api/items")).status, 401);
  assert.equal((await setup({ env: { SEKISHO: undefined } }).call("GET", "/api/items")).status, 401);
  const broken: Sekisho = {
    verify: async () => {
      throw new Error("down");
    },
  };
  assert.equal((await setup({ env: { SEKISHO: broken } }).call("GET", "/api/items")).status, 401);
});

test("拒んだ要求では書き込まれず、外へも取りに行かない", async () => {
  const s = setup();
  await s.call("POST", "/api/categories", { name: "仕事" }, "other.jwt");
  await s.call("POST", "/api/feeds", { url: "https://anikuma.example/" }, null);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM categories"), 0);
  assert.equal(s.count("SELECT COUNT(*) AS n FROM feeds"), 0);
  assert.equal(s.web.calls.length, 0);
});

test("ローカル開発の迂回は __LOCAL_DEV__ が無ければ効かない", async () => {
  const s = setup({ env: { DEV_BYPASS_AUTH: "1" } });
  assert.equal((await s.call("GET", "/api/items", undefined, null)).status, 401);
});
