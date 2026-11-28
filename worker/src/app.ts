// HTTP の口（Hono）。テストから時計と fetch を差し替えられるよう createApp で作る。
import { Hono, type Context } from "hono";
import type { AppEnv, Env } from "./env.ts";
import { apnsConfig, httpApnsSender, type ApnsSender } from "./apns.ts";
import { deleteDevice, normalizeAlerts, normalizeEnvironment, normalizeToken, sendNotices, upsertDevice, type Notice } from "./notify.ts";
import { requireAccess } from "./auth.ts";
import { addFeed, normalizeUrl, refreshFeed, type FetchDeps } from "./fetcher.ts";
import { handleMcp, MCP_BEARER_DEFAULT_SOURCE } from "./mcp.ts";
import { requireMcpToken } from "./mcp-auth.ts";
import { getEpisode, getPodcast, listEpisodes, listPodcasts } from "./podcast.ts";
import {
  addSocialPosts,
  categoryExists,
  createCategory,
  decodeCursor,
  decodeSocialBefore,
  isPlatform,
  listKnownPostIds,
  listSocialPosts,
  MAX_SOCIAL_POSTS,
  normalizeIsoTime,
  deleteCategory,
  deleteFeed,
  getFeedRow,
  getFeedView,
  getItem,
  isKind,
  isState,
  listCategories,
  listFeeds,
  listItems,
  listReadOn,
  listPawQueue,
  markPawSent,
  markPawSkipped,
  normalizeRururuItemId,
  normalizeSkipReason,
  jstDayRange,
  normalizeComment,
  normalizeName,
  setComment,
  setFeedCategory,
  setFeedRururuPaw,
  setRead,
  updateCategory,
} from "./store.ts";

export type AppDeps = FetchDeps & {
  /** APNs の送り口を env から作る（鍵が無ければ null）。テストではモックを返す */
  sender?: (env: Env) => ApnsSender | null;
};

/** 本番の APNs の送り口（APNS_* が揃っていなければ null） */
export function pushSender(env: Env): ApnsSender | null {
  const cfg = apnsConfig(env);
  return cfg ? httpApnsSender(cfg) : null;
}

export const defaultDeps: AppDeps = {
  now: () => new Date(),
  fetch: (input, init) => fetch(input, init),
  sender: pushSender,
};

type C = Context<AppEnv>;

function err(c: C, status: 400 | 404 | 409 | 422, error: string, extra: Record<string, unknown> = {}) {
  return c.json({ error, ...extra }, status);
}

async function body(c: C): Promise<Record<string, unknown>> {
  try {
    const v = await c.req.json();
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

function parseId(raw: string | undefined): number | null {
  return raw !== undefined && /^[1-9]\d{0,15}$/.test(raw) ? Number(raw) : null;
}

export function createApp(deps: AppDeps = defaultDeps) {
  const app = new Hono<AppEnv>();

  app.use("*", async (c, next) => {
    await next();
    c.header("X-Content-Type-Options", "nosniff");
    c.header("Cache-Control", "no-store");
  });
  app.use("/api/*", requireAccess);

  /** category_id: 数字（あるカテゴリ）か null（未分類）。undefined は「指定なし」 */
  async function categoryArg(c: C, v: unknown): Promise<number | null | undefined | "bad"> {
    if (v === undefined) return undefined;
    if (v === null) return null;
    if (typeof v === "number" && Number.isInteger(v) && v > 0 && (await categoryExists(c.env.DB, v))) return v;
    return "bad";
  }

  // ---------------- 記事 ----------------

  app.get("/api/items", async (c) => {
    const state = c.req.query("state") ?? "unread";
    if (!isState(state)) return err(c, 400, "bad_state");
    const cat = c.req.query("category");
    let category: number | "none" | undefined;
    if (cat !== undefined && cat !== "") {
      if (cat === "none") category = "none";
      else {
        const id = parseId(cat);
        if (id === null) return err(c, 400, "bad_category");
        category = id;
      }
    }
    const feedQ = c.req.query("feed");
    const feed = feedQ ? parseId(feedQ) : undefined;
    if (feed === null) return err(c, 400, "bad_feed");
    const beforeQ = c.req.query("before");
    const before = beforeQ ? decodeCursor(beforeQ) : undefined;
    if (before === null) return err(c, 400, "bad_cursor");
    const limitQ = c.req.query("limit");
    const limit = limitQ ? parseId(limitQ) ?? undefined : undefined;
    return c.json(await listItems(c.env.DB, { state, category, feed: feed ?? undefined, before, limit }));
  });

  /** 指定日（JST）に既読にした記事を read_at 昇順で（かけら帳 iOS の「読んだ記事」）。:id より先に置く */
  app.get("/api/items/read-on", async (c) => {
    const range = jstDayRange(c.req.query("date") ?? "");
    if (!range) return err(c, 400, "bad_date");
    return c.json({ items: await listReadOn(c.env.DB, range) });
  });

  /** 1件（通知をタップして開くとき） */
  app.get("/api/items/:id", async (c) => {
    const id = parseId(c.req.param("id"));
    const item = id === null ? null : await getItem(c.env.DB, id);
    return item ? c.json({ item }) : err(c, 404, "not_found");
  });

  app.post("/api/items/:id/read", async (c) => {
    const id = parseId(c.req.param("id"));
    const item = id === null ? null : await setRead(c.env.DB, id, true, deps.now());
    return item ? c.json({ item }) : err(c, 404, "not_found");
  });

  app.delete("/api/items/:id/read", async (c) => {
    const id = parseId(c.req.param("id"));
    const item = id === null ? null : await setRead(c.env.DB, id, false, deps.now());
    return item ? c.json({ item }) : err(c, 404, "not_found");
  });

  app.put("/api/items/:id/comment", async (c) => {
    const id = parseId(c.req.param("id"));
    if (id === null) return err(c, 404, "not_found");
    const comment = normalizeComment((await body(c)).comment);
    if (comment === undefined) return err(c, 400, "bad_comment");
    const item = await setComment(c.env.DB, id, comment, deps.now());
    return item ? c.json({ item }) : err(c, 404, "not_found");
  });

  // ---------------- カテゴリ ----------------

  app.get("/api/categories", async (c) => c.json(await listCategories(c.env.DB)));

  app.post("/api/categories", async (c) => {
    const name = normalizeName((await body(c)).name);
    if (!name) return err(c, 400, "bad_name");
    const id = await createCategory(c.env.DB, name, deps.now());
    const all = await listCategories(c.env.DB);
    return c.json({ category: all.categories.find((x) => x.id === id), ...all }, 201);
  });

  app.patch("/api/categories/:id", async (c) => {
    const id = parseId(c.req.param("id"));
    if (id === null) return err(c, 404, "not_found");
    const b = await body(c);
    const patch: { name?: string; sort?: number } = {};
    if (b.name !== undefined) {
      const n = normalizeName(b.name);
      if (!n) return err(c, 400, "bad_name");
      patch.name = n;
    }
    if (b.sort !== undefined) {
      if (typeof b.sort !== "number" || !Number.isInteger(b.sort) || b.sort < 0) return err(c, 400, "bad_sort");
      patch.sort = b.sort;
    }
    if (!(await updateCategory(c.env.DB, id, patch))) return err(c, 404, "not_found");
    return c.json(await listCategories(c.env.DB));
  });

  app.delete("/api/categories/:id", async (c) => {
    const id = parseId(c.req.param("id"));
    if (id === null || !(await deleteCategory(c.env.DB, id))) return err(c, 404, "not_found");
    return c.json(await listCategories(c.env.DB));
  });

  // ---------------- フィード ----------------

  /** kind=article（既定・サイト画面）｜podcast｜all */
  app.get("/api/feeds", async (c) => {
    const k = c.req.query("kind") ?? "article";
    if (k !== "all" && !isKind(k)) return err(c, 400, "bad_kind");
    return c.json({ feeds: await listFeeds(c.env.DB, k === "all" ? undefined : k) });
  });

  app.post("/api/feeds", async (c) => {
    const b = await body(c);
    const url = normalizeUrl(b.url);
    if (!url) return err(c, 400, "bad_url");
    const cat = await categoryArg(c, b.category_id);
    if (cat === "bad") return err(c, 400, "bad_category");
    const r = await addFeed(c.env.DB, url, cat ?? null, deps);
    if (r.kind === "error") return err(c, 422, r.error, r.detail ? { detail: r.detail } : {});
    const feed = await getFeedView(c.env.DB, r.id);
    return c.json({ feed, created: r.kind === "created" }, r.kind === "created" ? 201 : 200);
  });

  /** category_id（カテゴリの付け替え）と rururu_paw（rururu に送る・true/false）。どちらか片方だけでもよい */
  app.patch("/api/feeds/:id", async (c) => {
    const id = parseId(c.req.param("id"));
    if (id === null) return err(c, 404, "not_found");
    const b = await body(c);
    const cat = await categoryArg(c, b.category_id);
    if (cat === "bad") return err(c, 400, "bad_category");
    const paw = b.rururu_paw;
    if (paw !== undefined && typeof paw !== "boolean") return err(c, 400, "bad_rururu_paw");
    if (cat === undefined && paw === undefined) return err(c, 400, "bad_category");
    const row = await getFeedRow(c.env.DB, id);
    if (!row) return err(c, 404, "not_found");
    // 番組はカテゴリを持たない・rururu へも送らない（回は記事ではない）
    if (row.kind === "podcast" && ((cat !== undefined && cat !== null) || paw === true)) return err(c, 400, "bad_kind");
    if (cat !== undefined && !(await setFeedCategory(c.env.DB, id, cat))) return err(c, 404, "not_found");
    if (paw !== undefined && !(await setFeedRururuPaw(c.env.DB, id, paw))) return err(c, 404, "not_found");
    return c.json({ feed: await getFeedView(c.env.DB, id) });
  });

  app.delete("/api/feeds/:id", async (c) => {
    const id = parseId(c.req.param("id"));
    if (id === null || !(await deleteFeed(c.env.DB, id))) return err(c, 404, "not_found");
    return c.json({ ok: true });
  });

  app.post("/api/feeds/:id/refresh", async (c) => {
    const id = parseId(c.req.param("id"));
    const row = id === null ? null : await getFeedRow(c.env.DB, id);
    if (!row) return err(c, 404, "not_found");
    const notices: Notice[] = [];
    const r = await refreshFeed(c.env.DB, row, deps, notices);
    if (notices.length) {
      const sender = deps.sender?.(c.env) ?? null;
      c.executionCtx.waitUntil(
        sendNotices(c.env.DB, notices, sender).catch((e) => console.warn("notify: " + (e instanceof Error ? e.name : "error"))),
      );
    }
    return c.json({ feed: await getFeedView(c.env.DB, row.id), result: r });
  });

  // ---------------- rururu への paw キュー（段階2） ----------------

  /** まだ送っていない・飛ばしていないもの（積んだ順）。comment は送る時点の items.comment */
  app.get("/api/paw_queue", async (c) => c.json({ queue: await listPawQueue(c.env.DB) }));

  /** 送れた: { rururu_item_id }（rururu 側の item の id）を控える */
  app.post("/api/paw_queue/:item_id/sent", async (c) => {
    const id = parseId(c.req.param("item_id"));
    if (id === null) return err(c, 404, "not_found");
    const rid = normalizeRururuItemId((await body(c)).rururu_item_id);
    if (rid === null) return err(c, 400, "bad_rururu_item_id");
    const r = await markPawSent(c.env.DB, id, rid, deps.now());
    if (r === "not_found") return err(c, 404, "not_found");
    if (r === "already_sent") return err(c, 409, "already_sent");
    return c.json({ ok: true });
  });

  /** 送らずに外す: { reason }（not_in_rururu・already_pawed など） */
  app.post("/api/paw_queue/:item_id/skip", async (c) => {
    const id = parseId(c.req.param("item_id"));
    if (id === null) return err(c, 404, "not_found");
    const reason = normalizeSkipReason((await body(c)).reason);
    if (reason === null) return err(c, 400, "bad_reason");
    const r = await markPawSkipped(c.env.DB, id, reason, deps.now());
    if (r === "not_found") return err(c, 404, "not_found");
    if (r === "already_sent") return err(c, 409, "already_sent");
    return c.json({ ok: true });
  });

  // ---------------- ポッドキャスト（段階3） ----------------

  app.get("/api/podcasts", async (c) => c.json({ podcasts: await listPodcasts(c.env.DB) }));

  /** 番組を足す: { url }（フィードの URL か番組のサイト）。記事として購読済みなら番組へ移す（converted: true） */
  app.post("/api/podcasts", async (c) => {
    const url = normalizeUrl((await body(c)).url);
    if (!url) return err(c, 400, "bad_url");
    const r = await addFeed(c.env.DB, url, null, deps, "podcast");
    if (r.kind === "error") return err(c, 422, r.error, r.detail ? { detail: r.detail } : {});
    const podcast = await getPodcast(c.env.DB, r.id);
    if (!podcast) return err(c, 422, "not_podcast"); // 記事として購読済み、かつ移せなかった（来ない想定）
    return c.json({ podcast, created: r.kind === "created", converted: r.kind === "converted" }, r.kind === "created" ? 201 : 200);
  });

  app.get("/api/podcasts/:id", async (c) => {
    const id = parseId(c.req.param("id"));
    const podcast = id === null ? null : await getPodcast(c.env.DB, id);
    return podcast ? c.json({ podcast }) : err(c, 404, "not_found");
  });

  app.delete("/api/podcasts/:id", async (c) => {
    const id = parseId(c.req.param("id"));
    const row = id === null ? null : await getFeedRow(c.env.DB, id);
    if (!row || row.kind !== "podcast") return err(c, 404, "not_found");
    await deleteFeed(c.env.DB, row.id);
    return c.json({ ok: true });
  });

  /** エピソード一覧の問い合わせ（before=続き・after_id=その id より後を昇順で・limit） */
  function episodeQuery(c: C): { before?: { sort_at: string; id: number }; afterId?: number; limit?: number } | "bad_cursor" | "bad_after_id" {
    const beforeQ = c.req.query("before");
    const before = beforeQ ? decodeCursor(beforeQ) : undefined;
    if (before === null) return "bad_cursor";
    const afterQ = c.req.query("after_id");
    let afterId: number | undefined;
    if (afterQ !== undefined && afterQ !== "") {
      if (!/^\d{1,15}$/.test(afterQ)) return "bad_after_id";
      afterId = Number(afterQ);
    }
    const limitQ = c.req.query("limit");
    const limit = limitQ ? parseId(limitQ) ?? undefined : undefined;
    return { before, afterId, limit };
  }

  /** 番組ごとのエピソード一覧（新しい順） */
  app.get("/api/podcasts/:id/episodes", async (c) => {
    const id = parseId(c.req.param("id"));
    const row = id === null ? null : await getFeedRow(c.env.DB, id);
    if (!row || row.kind !== "podcast") return err(c, 404, "not_found");
    const q = episodeQuery(c);
    if (typeof q === "string") return err(c, 400, q);
    return c.json(await listEpisodes(c.env.DB, { ...q, feed: row.id }));
  });

  /** 全番組の新着（新しい順）。after_id で「まだ見ていない回」 */
  app.get("/api/episodes", async (c) => {
    const q = episodeQuery(c);
    if (typeof q === "string") return err(c, 400, q);
    return c.json(await listEpisodes(c.env.DB, q));
  });

  /** 1回の詳細（説明＝ショーノートの HTML つき・一覧には載せない） */
  app.get("/api/episodes/:id", async (c) => {
    const id = parseId(c.req.param("id"));
    const episode = id === null ? null : await getEpisode(c.env.DB, id);
    return episode ? c.json({ episode }) : err(c, 404, "not_found");
  });

  // ---------------- X・Instagram の投稿（段階4の小さな試し・ボットから受け取る） ----------------

  /** 投稿を入れる: 配列そのものか { posts: [...] }（最大 MAX_SOCIAL_POSTS 件）→ { inserted, skipped, rejected: [{ index, reason }] } */
  app.post("/api/social/posts", async (c) => {
    let raw: unknown;
    try {
      raw = await c.req.json();
    } catch {
      return err(c, 400, "bad_posts");
    }
    const posts = Array.isArray(raw) ? raw : raw && typeof raw === "object" ? (raw as Record<string, unknown>).posts : undefined;
    const r = await addSocialPosts(c.env.DB, posts, deps.now(), "api");
    if (r === "bad_posts") return err(c, 400, "bad_posts");
    if (r === "too_many_posts") return err(c, 400, "too_many_posts", { max: MAX_SOCIAL_POSTS });
    return c.json(r);
  });

  /** 一覧（新しい順）: platform=x|instagram（省略で両方）・before=<posted_at か next>・limit（既定 50・200 まで）→ { posts, next } */
  app.get("/api/social/posts", async (c) => {
    const pq = c.req.query("platform");
    if (pq !== undefined && pq !== "" && !isPlatform(pq)) return err(c, 400, "bad_platform");
    const bq = c.req.query("before");
    const before = bq ? decodeSocialBefore(bq) : undefined;
    if (before === null) return err(c, 400, "bad_before");
    const lq = c.req.query("limit");
    const limit = lq ? parseId(lq) : undefined;
    if (limit === null) return err(c, 400, "bad_limit");
    return c.json(await listSocialPosts(c.env.DB, { platform: pq ? (pq as "x" | "instagram") : undefined, before, limit }));
  });

  /** ボットの重複よけ: platform（必須）・since=<ISO 8601>（省略で直近7日）→ { platform, since, post_ids } */
  app.get("/api/social/known", async (c) => {
    const platform = c.req.query("platform");
    if (!isPlatform(platform)) return err(c, 400, "bad_platform");
    const sq = c.req.query("since");
    let since: string | undefined;
    if (sq) {
      const t = normalizeIsoTime(sq);
      if (!t) return err(c, 400, "bad_since");
      since = t;
    }
    return c.json(await listKnownPostIds(c.env.DB, platform, since, deps.now()));
  });

  // ---------------- MCP（Streamable HTTP・状態なし・JSON で返す） ----------------

  app.post("/api/mcp", (c) => handleMcp(c, deps.now()));
  // SSE の口（GET）・セッションの終わり（DELETE）は持たない
  app.on(["GET", "DELETE"], "/api/mcp", (c) => {
    c.header("Allow", "POST");
    return c.json({ error: "method_not_allowed" }, 405);
  });

  // /mcp: Access の外（Access 側でパスを素通しにする）。Worker 自身が Bearer（MCP_TOKENS）で守る。中身は /api/mcp と同じ
  app.use("/mcp", requireMcpToken);
  app.post("/mcp", (c) => handleMcp(c, deps.now(), MCP_BEARER_DEFAULT_SOURCE));
  app.on(["GET", "DELETE"], "/mcp", (c) => {
    c.header("Allow", "POST");
    return c.json({ error: "method_not_allowed" }, 405);
  });
  // OAuth の確認には「OAuth なし」と返す（認証なし）
  for (const path of [
    "/.well-known/oauth-protected-resource",
    "/.well-known/oauth-protected-resource/*",
    "/.well-known/oauth-authorization-server",
    "/.well-known/oauth-authorization-server/*",
    "/.well-known/openid-configuration",
  ]) {
    app.get(path, (c) => c.json({ error: "not_found" }, 404));
  }

  // ---------------- プッシュ通知の端末 ----------------

  /**
   * 登録（端末が起動のたびに送る・通知のオンオフに関係なく）。environment: development | production。
   * alerts: お知らせ（「メイン」の新着）を受け取るか（省略は true）。false でもサイレントプッシュ（番組の新しい回）は届く
   */
  app.put("/api/devices", async (c) => {
    const b = await body(c);
    const token = normalizeToken(b.token);
    if (!token) return err(c, 400, "bad_token");
    const environment = normalizeEnvironment(b.environment);
    if (!environment) return err(c, 400, "bad_environment");
    const alerts = normalizeAlerts(b.alerts);
    if (alerts === null) return err(c, 400, "bad_alerts");
    await upsertDevice(c.env.DB, token, environment, deps.now(), alerts);
    return c.json({ ok: true });
  });

  /** 外す（今のアプリは使わない・通知オフは alerts=false の PUT。古いビルドのために残す） */
  app.delete("/api/devices/:token", async (c) => {
    const token = normalizeToken(c.req.param("token"));
    if (!token) return err(c, 400, "bad_token");
    await deleteDevice(c.env.DB, token);
    return c.json({ ok: true });
  });

  app.notFound((c) => c.json({ error: "not_found" }, 404));
  app.onError((e, c) => {
    console.error("error: " + (e instanceof Error ? e.name : "unknown"));
    return c.json({ error: "internal" }, 500);
  });

  return app;
}
