// HTTP の口（Hono）。テストから時計と fetch を差し替えられるよう createApp で作る。
import { Hono, type Context } from "hono";
import type { AppEnv } from "./env.ts";
import { requireAccess } from "./auth.ts";
import { addFeed, normalizeUrl, refreshFeed, type FetchDeps } from "./fetcher.ts";
import {
  categoryExists,
  createCategory,
  decodeCursor,
  deleteCategory,
  deleteFeed,
  getFeedRow,
  getFeedView,
  isState,
  listCategories,
  listFeeds,
  listItems,
  normalizeComment,
  normalizeName,
  setComment,
  setFeedCategory,
  setRead,
  updateCategory,
} from "./store.ts";

export type AppDeps = FetchDeps;

export const defaultDeps: AppDeps = {
  now: () => new Date(),
  fetch: (input, init) => fetch(input, init),
};

type C = Context<AppEnv>;

function err(c: C, status: 400 | 404 | 422, error: string, extra: Record<string, unknown> = {}) {
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

  app.get("/api/feeds", async (c) => c.json({ feeds: await listFeeds(c.env.DB) }));

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

  app.patch("/api/feeds/:id", async (c) => {
    const id = parseId(c.req.param("id"));
    if (id === null) return err(c, 404, "not_found");
    const cat = await categoryArg(c, (await body(c)).category_id);
    if (cat === "bad" || cat === undefined) return err(c, 400, "bad_category");
    if (!(await setFeedCategory(c.env.DB, id, cat))) return err(c, 404, "not_found");
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
    const r = await refreshFeed(c.env.DB, row, deps);
    return c.json({ feed: await getFeedView(c.env.DB, row.id), result: r });
  });

  app.notFound((c) => c.json({ error: "not_found" }, 404));
  app.onError((e, c) => {
    console.error("error: " + (e instanceof Error ? e.name : "unknown"));
    return c.json({ error: "internal" }, 500);
  });

  return app;
}
