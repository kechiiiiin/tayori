// フィードを取りに行く（cron・足した直後・「いますぐ」）。fetch はテストから差し替える
import { findFeedLinks } from "./discover.ts";
import type { ApnsSender } from "./apns.ts";
import { pickNotices, sendNotices, sendWakeups, type Notice } from "./notify.ts";
import { absUrl, parseFeed, type ParsedFeed } from "./parse.ts";
import { convertToPodcast, upsertEpisodes } from "./podcast.ts";
import {
  findFeedByUrl,
  getFeedRow,
  insertFeed,
  insertItems,
  markFetched,
  purgeOld,
  staleFeeds,
  type FeedKind,
  type FeedRow,
} from "./store.ts";

export type FetchFn = (input: string, init?: RequestInit) => Promise<Response>;

export interface FetchDeps {
  fetch: FetchFn;
  now: () => Date;
  timeoutMs?: number;
  /** 「メイン」の新着を知らせる APNs の送り口。無ければ（鍵が無い・テスト）送らない */
  push?: ApnsSender | null;
}

export const USER_AGENT = "tayori/0.1 (personal feed reader)";
const FETCH_TIMEOUT_MS = 10_000;
// ポッドキャストのフィードは全話入りで 5〜10MB になる（rururu の購読に 8.7MB のものがあった）
const MAX_BODY = 16 * 1024 * 1024;
/** cron 1回で取りに行く数の既定（Workers Free の subrequest 50 に収まる量） */
export const DEFAULT_FETCH_PER_RUN = 15;
const CONCURRENCY = 6;

const ACCEPT = "application/rss+xml, application/atom+xml, application/feed+json, application/xml;q=0.9, text/xml;q=0.9, text/html;q=0.8, */*;q=0.5";

interface Got {
  status: number;
  url: string;
  body: string;
  etag: string | null;
  last_modified: string | null;
}

/** 取得の失敗を人に読める短い文に */
export class FetchError extends Error {}

async function get(deps: FetchDeps, url: string, cond?: { etag: string | null; last_modified: string | null }): Promise<Got> {
  const headers: Record<string, string> = { "User-Agent": USER_AGENT, Accept: ACCEPT };
  if (cond?.etag) headers["If-None-Match"] = cond.etag;
  if (cond?.last_modified) headers["If-Modified-Since"] = cond.last_modified;
  let res: Response;
  try {
    res = await deps.fetch(url, { headers, redirect: "follow", signal: AbortSignal.timeout(deps.timeoutMs ?? FETCH_TIMEOUT_MS) });
  } catch (e) {
    const name = e instanceof Error ? e.name : "";
    throw new FetchError(name === "TimeoutError" || name === "AbortError" ? "タイムアウト" : "通信エラー");
  }
  const finalUrl = res.url || url;
  if (res.status === 304) return { status: 304, url: finalUrl, body: "", etag: null, last_modified: null };
  if (!res.ok) throw new FetchError(`HTTP ${res.status}`);
  const buf = await res.arrayBuffer();
  if (buf.byteLength > MAX_BODY) throw new FetchError("大きすぎます");
  return {
    status: res.status,
    url: finalUrl,
    body: decode(buf, res.headers.get("content-type")),
    etag: res.headers.get("etag"),
    last_modified: res.headers.get("last-modified"),
  };
}

/** 文字コード: Content-Type の charset → XML 宣言／meta の charset → UTF-8 */
function decode(buf: ArrayBuffer, contentType: string | null): string {
  const head = new TextDecoder("latin1").decode(buf.slice(0, 1024));
  const label =
    /charset=["']?([\w-]+)/i.exec(contentType ?? "")?.[1] ??
    /<\?xml[^>]*encoding=["']([\w-]+)["']/i.exec(head)?.[1] ??
    /<meta[^>]*charset=["']?([\w-]+)/i.exec(head)?.[1] ??
    "utf-8";
  try {
    return new TextDecoder(label.toLowerCase()).decode(buf);
  } catch {
    return new TextDecoder("utf-8").decode(buf);
  }
}

export type RefreshResult = { status: "ok"; added: number } | { status: "not_modified"; added: 0 } | { status: "error"; error: string; added: 0 };

/**
 * 1本取りに行く。304 なら記事には触らない。失敗は last_error に残す。
 * notices を渡すと、知らせる新着（notify.ts の pickNotices）をそこへ足す（送るのは呼んだ側）
 */
export async function refreshFeed(db: D1Database, feed: FeedRow, deps: FetchDeps, notices?: Notice[]): Promise<RefreshResult> {
  const now = deps.now();
  try {
    const got = await get(deps, feed.feed_url, { etag: feed.etag, last_modified: feed.last_modified });
    if (got.status === 304) {
      await markFetched(db, feed.id, {}, now);
      return { status: "not_modified", added: 0 };
    }
    const parsed = parseFeed(got.body, got.url);
    if (!parsed) throw new FetchError("フィードとして読めません");
    const fetched = { etag: got.etag, last_modified: got.last_modified, site_url: parsed.site_url, image_url: parsed.image_url };
    if (feed.kind === "podcast") {
      // 番組: 新しい回だけ episodes へ（上限なし・既知の回は書かない）。お知らせは鳴らさない（「メイン」のカテゴリに入らない）。
      // 新しい回が入ったら refreshDue がサイレントプッシュで端末を起こす
      const added = await upsertEpisodes(db, feed.id, parsed.items, now);
      await markFetched(db, feed.id, fetched, now);
      return { status: "ok", added };
    }
    const inserted = await insertItems(db, feed.id, parsed.items, now, false);
    await markFetched(db, feed.id, fetched, now);
    if (notices && inserted.length) notices.push(...(await pickNotices(db, feed.id, inserted, now)));
    return { status: "ok", added: inserted.length };
  } catch (e) {
    const error = e instanceof FetchError ? e.message : "取得に失敗しました";
    if (!(e instanceof FetchError)) console.warn("refresh: " + (e instanceof Error ? e.name : "error"));
    await markFetched(db, feed.id, { error }, now);
    return { status: "error", error, added: 0 };
  }
}

/**
 * 古い順に limit 本を取りに行く（同時に CONCURRENCY 本まで）。終わったら「メイン」の新着を知らせる。
 * 番組に新しい回が1つでも入ったら、登録済みの端末それぞれへサイレントプッシュを1通（何本・何回入っても1回の実行で1通）
 */
export async function refreshDue(db: D1Database, deps: FetchDeps, limit: number) {
  const feeds = await staleFeeds(db, limit);
  const results: RefreshResult[] = [];
  const notices: Notice[] = [];
  let episodes = 0; // 番組に新しく入った回の数
  let next = 0;
  async function worker() {
    while (next < feeds.length) {
      const f = feeds[next++];
      const r = await refreshFeed(db, f, deps, notices);
      if (f.kind === "podcast") episodes += r.added;
      results.push(r);
    }
  }
  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, feeds.length) }, worker));
  let pushed = 0;
  try {
    pushed = (await sendNotices(db, notices, deps.push)).sent;
  } catch (e) {
    console.warn("notify: " + (e instanceof Error ? e.name : "error"));
  }
  let woken = 0;
  if (episodes > 0) {
    try {
      woken = await sendWakeups(db, deps.push);
    } catch (e) {
      console.warn("wakeup: " + (e instanceof Error ? e.name : "error"));
    }
  }
  return {
    fetched: feeds.length,
    added: results.reduce((a, r) => a + r.added, 0),
    errors: results.filter((r) => r.status === "error").length,
    notices: notices.length,
    pushed,
    episodes,
    woken,
  };
}

/** cron: 古い記事を消してから、取りに行く */
export async function runScheduled(db: D1Database, deps: FetchDeps, perRun: number) {
  const purged = await purgeOld(db, deps.now());
  const r = await refreshDue(db, deps, perRun);
  console.log(`cron: fetched=${r.fetched} added=${r.added} errors=${r.errors} purged=${purged} notices=${r.notices} pushed=${r.pushed} episodes=${r.episodes} woken=${r.woken}`);
  return { ...r, purged };
}

export function parsePerRun(v: string | undefined): number {
  const n = Number(v);
  return Number.isInteger(n) && n > 0 && n <= 500 ? n : DEFAULT_FETCH_PER_RUN;
}

/** 貼られた文字を URL に（スキームが無ければ https://）。http(s) 以外は null */
export function normalizeUrl(v: unknown): string | null {
  if (typeof v !== "string") return null;
  let s = v.trim();
  if (!s || s.length > 2000 || /\s/.test(s)) return null;
  if (!/^[a-z][a-z0-9+.-]*:/i.test(s)) s = "https://" + s.replace(/^\/+/, "");
  const u = absUrl(s, "https://invalid.invalid/");
  if (!u) return null;
  const host = new URL(u).hostname;
  return host && host.includes(".") ? u : null;
}

export type AddResult =
  | { kind: "created"; id: number }
  | { kind: "exists"; id: number }
  /** 記事として購読していたフィードを番組として足した（番組へ移して取り直した） */
  | { kind: "converted"; id: number }
  | { kind: "error"; error: "fetch_failed" | "feed_not_found"; detail?: string };

/**
 * サイトか RSS の URL から購読を足す:
 * 1. 貼った URL を取りに行き、フィードとして読めればそれ
 * 2. HTML なら <link rel="alternate"> の候補を上から試す（最大3本）
 * 3. どれもだめなら feed_not_found
 * 足したら直近 INITIAL_ITEMS 件を未読で入れる。
 * kind = podcast（番組として足す）はカテゴリを持たず、フィードにある回を全部 episodes へ入れる。
 * 記事として購読済みのフィードを番組として足したら、番組へ移して取り直す
 */
export async function addFeed(
  db: D1Database,
  rawUrl: string,
  categoryId: number | null,
  deps: FetchDeps,
  kind: FeedKind = "article",
): Promise<AddResult> {
  const exists = async (id: number): Promise<AddResult> => {
    if (kind !== "podcast") return { kind: "exists", id };
    const row = await getFeedRow(db, id);
    if (!row || row.kind === "podcast") return { kind: "exists", id };
    await convertToPodcast(db, id);
    const fresh = await getFeedRow(db, id);
    if (fresh) await refreshFeed(db, fresh, deps);
    return { kind: "converted", id };
  };
  const existing = await findFeedByUrl(db, rawUrl);
  if (existing) return exists(existing);

  let page: Got;
  try {
    page = await get(deps, rawUrl);
  } catch (e) {
    return { kind: "error", error: "fetch_failed", detail: e instanceof Error ? e.message : undefined };
  }

  let feedUrl = page.url;
  let got = page;
  let parsed: ParsedFeed | null = parseFeed(page.body, page.url);
  if (!parsed) {
    for (const cand of findFeedLinks(page.body, page.url).slice(0, 3)) {
      const ex = await findFeedByUrl(db, cand);
      if (ex) return exists(ex);
      try {
        const g = await get(deps, cand);
        const p = parseFeed(g.body, g.url);
        if (p) {
          parsed = p;
          got = g;
          feedUrl = cand;
          break;
        }
      } catch {
        // 次の候補へ
      }
    }
  }
  if (!parsed) return { kind: "error", error: "feed_not_found" };

  const again = await findFeedByUrl(db, feedUrl);
  if (again) return exists(again);

  const now = deps.now();
  const siteUrl = parsed.site_url ?? (got === page ? null : page.url) ?? new URL(feedUrl).origin + "/";
  const id = await insertFeed(
    db,
    {
      kind,
      category_id: kind === "podcast" ? null : categoryId,
      title: parsed.title || new URL(siteUrl).hostname,
      site_url: siteUrl,
      feed_url: feedUrl,
      image_url: parsed.image_url,
      etag: got.etag,
      last_modified: got.last_modified,
    },
    now,
  );
  // 初めての取り込みは知らせない（古い記事がまとめて入るため）
  if (kind === "podcast") await upsertEpisodes(db, id, parsed.items, now);
  else await insertItems(db, id, parsed.items, now, true);
  return { kind: "created", id };
}
