// テストの下まわり: D1（node:sqlite）・関所のモック・差し替えられる fetch と時計
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createApp, type AppDeps } from "../src/app.ts";
import type { Env } from "../src/env.ts";
import type { Sekisho } from "../src/auth.ts";
import type { FetchDeps } from "../src/fetcher.ts";
import { makeDb } from "./d1shim.ts";

export const AUD = "test-aud";
export const CLIENT_ID = "abc123def456.access";

export function fixture(name: string): string {
  return readFileSync(join(dirname(fileURLToPath(import.meta.url)), "fixtures", name), "utf8");
}

/** 関所のふり: "ok.jwt" = 許可された Client ID、"other.jwt" = 許可外の Client ID、"user.jwt" = ブラウザのユーザー */
export function mockSekisho(): Sekisho {
  return {
    async verify(token, aud, opts) {
      if (aud !== AUD || opts?.allowServiceTokens !== true) return null;
      if (token === "ok.jwt") return { kind: "service", clientId: CLIENT_ID.toUpperCase() };
      if (token === "other.jwt") return { kind: "service", clientId: "9999.access" };
      if (token === "user.jwt") return { kind: "user", email: "someone@example.com" };
      return null;
    },
  };
}

export class Clock {
  t: number;
  constructor(iso: string) {
    this.t = Date.parse(iso);
  }
  now = () => new Date(this.t);
  set(iso: string) {
    this.t = Date.parse(iso);
  }
  addDays(d: number) {
    this.t += d * 86400_000;
  }
}

export interface Route {
  status?: number;
  body?: string;
  headers?: Record<string, string>;
  /** 条件付き GET の答え（If-None-Match が etag と一致したら 304） */
  etag?: string;
  /** 投げる（通信エラー） */
  throws?: boolean;
}

/** URL → 応答 の表で答える fetch。呼ばれた URL と送られたヘッダを残す */
export class MockWeb {
  routes = new Map<string, Route>();
  calls: { url: string; headers: Record<string, string> }[] = [];
  set(url: string, r: Route) {
    this.routes.set(url, r);
  }
  fetch = async (input: string, init?: RequestInit): Promise<Response> => {
    const headers = Object.fromEntries(Object.entries((init?.headers as Record<string, string>) ?? {}).map(([k, v]) => [k.toLowerCase(), v]));
    this.calls.push({ url: input, headers });
    const r = this.routes.get(input);
    if (!r) return new Response("not found", { status: 404 });
    if (r.throws) throw new TypeError("network");
    if (r.etag && headers["if-none-match"] === r.etag) return new Response(null, { status: 304 });
    const h = new Headers(r.headers ?? {});
    if (r.etag) h.set("ETag", r.etag);
    return new Response(r.body ?? "", { status: r.status ?? 200, headers: h });
  };
}

/** n 件の RSS（新しい順・1日ずつ古くなる）。prefix で guid を変える */
export function rssWith(n: number, opts: { prefix?: string; start?: string; title?: string } = {}): string {
  const start = Date.parse(opts.start ?? "2026-11-18T00:00:00Z");
  const items = Array.from({ length: n }, (_, i) => {
    const d = new Date(start - i * 86400_000).toUTCString();
    return `<item><title>記事 ${i + 1}</title><link>https://many.example/${opts.prefix ?? "p"}/${i + 1}</link><guid>${opts.prefix ?? "p"}-${i + 1}</guid><pubDate>${d}</pubDate></item>`;
  }).join("\n");
  return `<?xml version="1.0"?><rss version="2.0"><channel><title>${opts.title ?? "たくさん"}</title><link>https://many.example/</link>${items}</channel></rss>`;
}

export function setup(o: { now?: string; env?: Partial<Env> } = {}) {
  const { db, raw } = makeDb();
  const clock = new Clock(o.now ?? "2026-11-18T03:00:00Z");
  const web = new MockWeb();
  const env = {
    DB: db,
    SEKISHO: mockSekisho(),
    CF_ACCESS_AUD: AUD,
    ACCESS_SERVICE_CLIENT_IDS: CLIENT_ID,
    ...o.env,
  } as Env;
  const deps: AppDeps & FetchDeps = { now: clock.now, fetch: web.fetch };
  const app = createApp(deps);
  const ctx = {
    waitUntil: () => {},
    passThroughOnException() {},
    props: {},
  } as unknown as ExecutionContext;

  async function call(method: string, path: string, body?: unknown, token: string | null = "ok.jwt") {
    const headers: Record<string, string> = {};
    if (token) headers["Cf-Access-Jwt-Assertion"] = token;
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const res = await app.request(
      `https://tayori.example.com${path}`,
      { method, headers, body: body === undefined ? undefined : JSON.stringify(body) },
      env,
      ctx,
    );
    const json = (await res.json()) as any;
    return { status: res.status, json };
  }
  function count(sql: string, ...args: (string | number | null)[]): number {
    return Number((raw.prepare(sql).get(...args) as { n: number }).n);
  }
  return { db, raw, clock, web, env, deps, call, count };
}

/** n 回のポッドキャストの RSS（新しい順・1日ずつ古くなる・どの回にも音声と長さ＝回の番号で決まる）。prefix で guid を変える */
export function podcastWith(n: number, opts: { prefix?: string; start?: string; title?: string } = {}): string {
  const start = Date.parse(opts.start ?? "2026-11-18T00:00:00Z");
  const p = opts.prefix ?? "e";
  const items = Array.from({ length: n }, (_, i) => {
    const d = new Date(start - i * 86400_000).toUTCString();
    return `<item><title>第${n - i}回</title><guid>${p}-${n - i}</guid><pubDate>${d}</pubDate><enclosure url="https://cdn.pod.example/${p}/${n - i}.mp3" type="audio/mpeg" length="1"/><itunes:duration>${600 + n - i}</itunes:duration></item>`;
  }).join("\n");
  return `<?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>${opts.title ?? "長寿番組"}</title><link>https://pod.example/</link><itunes:image href="https://pod.example/art.jpg"/>${items}</channel></rss>`;
}
