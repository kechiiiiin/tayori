// D1 の読み書き（カテゴリ・フィード・記事）。ネットワークには出ない（取りに行くのは fetcher.ts）
import { newest, type ParsedItem } from "./parse.ts";

export type ItemState = "unread" | "commented" | "all";

/** 初めて足したフィードで未読として入れる件数 */
export const INITIAL_ITEMS = 20;
/** 既読でコメントの無い記事を消すまでの日数 */
export const PURGE_DAYS = 90;
export const PAGE_SIZE = 50;
export const MAX_COMMENT = 4000;
export const MAX_CATEGORY_NAME = 40;

export interface CategoryView {
  id: number;
  name: string;
  sort: number;
  unread: number;
  commented: number;
}

export interface FeedView {
  id: number;
  category_id: number | null;
  title: string;
  site_url: string | null;
  feed_url: string;
  /** ポッドキャストの番組アートワーク（itunes:image）。無ければ null */
  image_url: string | null;
  last_fetched_at: string | null;
  last_error: string | null;
  unread: number;
  created_at: string;
}

export interface ItemView {
  id: number;
  feed_id: number;
  feed_title: string;
  category_id: number | null;
  title: string;
  url: string | null;
  published_at: string | null;
  sort_at: string;
  read_at: string | null;
  comment: string | null;
  comment_updated_at: string | null;
}

export interface FeedRow {
  id: number;
  category_id: number | null;
  title: string;
  site_url: string | null;
  feed_url: string;
  image_url: string | null;
  etag: string | null;
  last_modified: string | null;
  last_fetched_at: string | null;
  last_error: string | null;
}

// ---------------- カテゴリ ----------------

export async function listCategories(db: D1Database) {
  const rows = (
    await db
      .prepare(
        `SELECT c.id, c.name, c.sort,
                COALESCE(SUM(CASE WHEN i.id IS NOT NULL AND i.read_at IS NULL THEN 1 ELSE 0 END), 0) AS unread,
                COALESCE(SUM(CASE WHEN i.comment IS NOT NULL THEN 1 ELSE 0 END), 0) AS commented
           FROM categories c
           LEFT JOIN feeds f ON f.category_id = c.id
           LEFT JOIN items i ON i.feed_id = f.id
          GROUP BY c.id
          ORDER BY c.sort, c.id`,
      )
      .all<CategoryView>()
  ).results;
  const none = await db
    .prepare(
      `SELECT COALESCE(SUM(CASE WHEN i.id IS NOT NULL AND i.read_at IS NULL THEN 1 ELSE 0 END), 0) AS unread,
              COALESCE(SUM(CASE WHEN i.comment IS NOT NULL THEN 1 ELSE 0 END), 0) AS commented
         FROM items i JOIN feeds f ON f.id = i.feed_id
        WHERE f.category_id IS NULL`,
    )
    .first<{ unread: number; commented: number }>();
  const uncategorized = { unread: Number(none?.unread ?? 0), commented: Number(none?.commented ?? 0) };
  const categories = rows.map((r) => ({ ...r, unread: Number(r.unread), commented: Number(r.commented) }));
  const total = {
    unread: categories.reduce((a, c) => a + c.unread, uncategorized.unread),
    commented: categories.reduce((a, c) => a + c.commented, uncategorized.commented),
  };
  return { categories, uncategorized, total };
}

export function normalizeName(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const s = v.replace(/\s+/g, " ").trim();
  return s && [...s].length <= MAX_CATEGORY_NAME ? s : null;
}

export async function categoryExists(db: D1Database, id: number): Promise<boolean> {
  return !!(await db.prepare("SELECT 1 AS x FROM categories WHERE id = ?").bind(id).first());
}

export async function createCategory(db: D1Database, name: string, now: Date): Promise<number> {
  const r = await db
    .prepare(
      "INSERT INTO categories (name, sort, created_at) VALUES (?, (SELECT COALESCE(MAX(sort), -1) + 1 FROM categories), ?) RETURNING id",
    )
    .bind(name, now.toISOString())
    .first<{ id: number }>();
  return Number(r!.id);
}

/** 名前と並び。sort は「何番目に置くか」（0 から）。他のカテゴリは詰め直す */
export async function updateCategory(db: D1Database, id: number, patch: { name?: string; sort?: number }): Promise<boolean> {
  if (!(await categoryExists(db, id))) return false;
  if (patch.name !== undefined) await db.prepare("UPDATE categories SET name = ? WHERE id = ?").bind(patch.name, id).run();
  if (patch.sort !== undefined) {
    const ids = (await db.prepare("SELECT id FROM categories ORDER BY sort, id").all<{ id: number }>()).results
      .map((r) => Number(r.id))
      .filter((x) => x !== id);
    const at = Math.max(0, Math.min(patch.sort, ids.length));
    ids.splice(at, 0, id);
    await db.batch(ids.map((cid, i) => db.prepare("UPDATE categories SET sort = ? WHERE id = ?").bind(i, cid)));
  }
  return true;
}

/** 消す。中のサイトは未分類へ */
export async function deleteCategory(db: D1Database, id: number): Promise<boolean> {
  if (!(await categoryExists(db, id))) return false;
  await db.batch([
    db.prepare("UPDATE feeds SET category_id = NULL WHERE category_id = ?").bind(id),
    db.prepare("DELETE FROM categories WHERE id = ?").bind(id),
  ]);
  return true;
}

// ---------------- フィード ----------------

const FEED_VIEW = `SELECT f.id, f.category_id, f.title, f.site_url, f.feed_url, f.image_url, f.last_fetched_at, f.last_error, f.created_at,
       (SELECT COUNT(*) FROM items i WHERE i.feed_id = f.id AND i.read_at IS NULL) AS unread
  FROM feeds f`;

function feedView(r: FeedView): FeedView {
  return { ...r, unread: Number(r.unread) };
}

export async function listFeeds(db: D1Database): Promise<FeedView[]> {
  const rows = (await db.prepare(`${FEED_VIEW} ORDER BY f.title COLLATE NOCASE, f.id`).all<FeedView>()).results;
  return rows.map(feedView);
}

export async function getFeedView(db: D1Database, id: number): Promise<FeedView | null> {
  const r = await db.prepare(`${FEED_VIEW} WHERE f.id = ?`).bind(id).first<FeedView>();
  return r ? feedView(r) : null;
}

export async function getFeedRow(db: D1Database, id: number): Promise<FeedRow | null> {
  return db.prepare("SELECT * FROM feeds WHERE id = ?").bind(id).first<FeedRow>();
}

export async function findFeedByUrl(db: D1Database, feedUrl: string): Promise<number | null> {
  const r = await db.prepare("SELECT id FROM feeds WHERE feed_url = ?").bind(feedUrl).first<{ id: number }>();
  return r ? Number(r.id) : null;
}

export async function insertFeed(
  db: D1Database,
  f: {
    category_id: number | null;
    title: string;
    site_url: string | null;
    feed_url: string;
    image_url: string | null;
    etag: string | null;
    last_modified: string | null;
  },
  now: Date,
): Promise<number> {
  const at = now.toISOString();
  const r = await db
    .prepare(
      `INSERT INTO feeds (category_id, title, site_url, feed_url, image_url, etag, last_modified, last_fetched_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id`,
    )
    .bind(f.category_id, f.title, f.site_url, f.feed_url, f.image_url, f.etag, f.last_modified, at, at)
    .first<{ id: number }>();
  return Number(r!.id);
}

export async function setFeedCategory(db: D1Database, id: number, categoryId: number | null): Promise<boolean> {
  const r = await db.prepare("UPDATE feeds SET category_id = ? WHERE id = ?").bind(categoryId, id).run();
  return (r.meta?.changes ?? 0) > 0;
}

/** 外す。記事（コメントごと）・控え・paw_queue も消す */
export async function deleteFeed(db: D1Database, id: number): Promise<boolean> {
  if (!(await getFeedRow(db, id))) return false;
  await db.batch([
    db.prepare("DELETE FROM paw_queue WHERE item_id IN (SELECT id FROM items WHERE feed_id = ?)").bind(id),
    db.prepare("DELETE FROM items WHERE feed_id = ?").bind(id),
    db.prepare("DELETE FROM item_tombstones WHERE feed_id = ?").bind(id),
    db.prepare("DELETE FROM feeds WHERE id = ?").bind(id),
  ]);
  return true;
}

/**
 * 取得の結果を残す（成功・304 は last_error を消す）。
 * image_url は本文を読めたときだけ渡す（その時点のアートワークで上書き・無くなれば null）。304・失敗では触らない
 */
export async function markFetched(
  db: D1Database,
  id: number,
  r: { etag?: string | null; last_modified?: string | null; error?: string | null; site_url?: string | null; image_url?: string | null },
  now: Date,
) {
  if (r.error) {
    await db.prepare("UPDATE feeds SET last_fetched_at = ?, last_error = ? WHERE id = ?").bind(now.toISOString(), r.error, id).run();
    return;
  }
  await db
    .prepare(
      `UPDATE feeds SET last_fetched_at = ?, last_error = NULL,
              etag = COALESCE(?, etag), last_modified = COALESCE(?, last_modified), site_url = COALESCE(site_url, ?)
        WHERE id = ?`,
    )
    .bind(now.toISOString(), r.etag ?? null, r.last_modified ?? null, r.site_url ?? null, id)
    .run();
  if (r.image_url !== undefined) {
    await db.prepare("UPDATE feeds SET image_url = ? WHERE id = ?").bind(r.image_url, id).run();
  }
}

/** 取りに行く順（古い順・まだ一度も取っていないものが先） */
export async function staleFeeds(db: D1Database, limit: number): Promise<FeedRow[]> {
  return (
    await db
      .prepare("SELECT * FROM feeds ORDER BY last_fetched_at IS NOT NULL, last_fetched_at, id LIMIT ?")
      .bind(limit)
      .all<FeedRow>()
  ).results;
}

// ---------------- 記事 ----------------

/**
 * 取ってきた記事を入れる。(feed_id, guid) が items にも控え（item_tombstones）にも無いものだけ。
 * initial（初めて足したフィード）は新しい順に INITIAL_ITEMS 件だけ未読で入れ、残りは控えに回す。
 * D1 の束縛変数の上限（100）に掛からないよう、行は JSON 1つで渡して json_each で展開する
 */
export async function insertItems(db: D1Database, feedId: number, items: ParsedItem[], now: Date, initial: boolean): Promise<number> {
  const seen = new Set<string>();
  const unique = items.filter((i) => (seen.has(i.guid) ? false : (seen.add(i.guid), true)));
  if (!unique.length) return 0;
  const known = new Set(
    (
      await db
        .prepare("SELECT guid FROM items WHERE feed_id = ?1 UNION SELECT guid FROM item_tombstones WHERE feed_id = ?1")
        .bind(feedId)
        .all<{ guid: string }>()
    ).results.map((r) => r.guid),
  );
  const fresh = unique.filter((i) => !known.has(i.guid));
  if (!fresh.length) return 0;
  const keep = initial ? newest(fresh, INITIAL_ITEMS) : fresh;
  const keepSet = new Set(keep.map((i) => i.guid));
  const skip = fresh.filter((i) => !keepSet.has(i.guid));
  const at = now.toISOString();
  const rows = keep.map((i) => ({
    guid: i.guid,
    url: i.url,
    title: i.title,
    published_at: i.published_at,
    sort_at: i.published_at && i.published_at <= at ? i.published_at : at,
  }));
  const stmts = [
    db
      .prepare(
        `INSERT OR IGNORE INTO items (feed_id, guid, url, title, published_at, fetched_at, sort_at)
         SELECT ?1, json_extract(value, '$.guid'), json_extract(value, '$.url'), json_extract(value, '$.title'),
                json_extract(value, '$.published_at'), ?2, json_extract(value, '$.sort_at')
           FROM json_each(?3)`,
      )
      .bind(feedId, at, JSON.stringify(rows)),
  ];
  if (skip.length) {
    stmts.push(
      db
        .prepare("INSERT OR IGNORE INTO item_tombstones (feed_id, guid, created_at) SELECT ?1, value, ?2 FROM json_each(?3)")
        .bind(feedId, at, JSON.stringify(skip.map((i) => i.guid))),
    );
  }
  await db.batch(stmts);
  return rows.length;
}

const ITEM_VIEW = `SELECT i.id, i.feed_id, f.title AS feed_title, f.category_id, i.title, i.url, i.published_at, i.sort_at,
       i.read_at, i.comment, i.comment_updated_at
  FROM items i JOIN feeds f ON f.id = i.feed_id`;

export function isState(v: unknown): v is ItemState {
  return v === "unread" || v === "commented" || v === "all";
}

/** カーソル = 最後の行の "sort_at|id" */
export function encodeCursor(i: { sort_at: string; id: number }): string {
  return `${i.sort_at}|${i.id}`;
}
export function decodeCursor(s: string): { sort_at: string; id: number } | null {
  const m = /^(\d{4}-\d{2}-\d{2}T[\d:.]+Z)\|(\d{1,15})$/.exec(s);
  return m ? { sort_at: m[1], id: Number(m[2]) } : null;
}

export async function listItems(
  db: D1Database,
  q: { state: ItemState; category?: number | "none"; feed?: number; before?: { sort_at: string; id: number }; limit?: number },
): Promise<{ items: ItemView[]; next: string | null }> {
  const where: string[] = [];
  const args: (string | number)[] = [];
  if (q.state === "unread") where.push("i.read_at IS NULL");
  if (q.state === "commented") where.push("i.comment IS NOT NULL");
  if (q.category === "none") where.push("f.category_id IS NULL");
  else if (q.category !== undefined) {
    where.push("f.category_id = ?");
    args.push(q.category);
  }
  if (q.feed !== undefined) {
    where.push("i.feed_id = ?");
    args.push(q.feed);
  }
  if (q.before) {
    where.push("(i.sort_at < ? OR (i.sort_at = ? AND i.id < ?))");
    args.push(q.before.sort_at, q.before.sort_at, q.before.id);
  }
  const limit = Math.max(1, Math.min(q.limit ?? PAGE_SIZE, 200));
  const sql = `${ITEM_VIEW}${where.length ? " WHERE " + where.join(" AND ") : ""} ORDER BY i.sort_at DESC, i.id DESC LIMIT ?`;
  const rows = (
    await db
      .prepare(sql)
      .bind(...args, limit + 1)
      .all<ItemView>()
  ).results;
  const items = rows.slice(0, limit);
  return { items, next: rows.length > limit ? encodeCursor(items[items.length - 1]) : null };
}

export async function getItem(db: D1Database, id: number): Promise<ItemView | null> {
  return db.prepare(`${ITEM_VIEW} WHERE i.id = ?`).bind(id).first<ItemView>();
}

/** 既読にする（もう既読なら時刻は変えない）／戻す */
export async function setRead(db: D1Database, id: number, read: boolean, now: Date): Promise<ItemView | null> {
  const r = read
    ? await db.prepare("UPDATE items SET read_at = COALESCE(read_at, ?) WHERE id = ?").bind(now.toISOString(), id).run()
    : await db.prepare("UPDATE items SET read_at = NULL WHERE id = ?").bind(id).run();
  if ((r.meta?.changes ?? 0) === 0) return null;
  return getItem(db, id);
}

export function normalizeComment(v: unknown): string | null | undefined {
  if (typeof v !== "string") return undefined; // 不正
  const s = v.replace(/\r\n?/g, "\n").trim();
  if (!s) return null; // 空 = 消す
  return [...s].length <= MAX_COMMENT ? s : undefined;
}

export async function setComment(db: D1Database, id: number, comment: string | null, now: Date): Promise<ItemView | null> {
  const r = await db
    .prepare("UPDATE items SET comment = ?, comment_updated_at = ? WHERE id = ?")
    .bind(comment, comment === null ? null : now.toISOString(), id)
    .run();
  if ((r.meta?.changes ?? 0) === 0) return null;
  return getItem(db, id);
}

/** 既読になって PURGE_DAYS 日たち、コメントの無い記事を消す（guid は控えに残し、次の取得で戻らないように） */
export async function purgeOld(db: D1Database, now: Date): Promise<number> {
  const cutoff = new Date(now.getTime() - PURGE_DAYS * 86400_000).toISOString();
  const cond = "read_at IS NOT NULL AND read_at < ?1 AND comment IS NULL";
  const out = await db.batch([
    db.prepare(`INSERT OR IGNORE INTO item_tombstones (feed_id, guid, created_at) SELECT feed_id, guid, ?2 FROM items WHERE ${cond}`).bind(cutoff, now.toISOString()),
    db.prepare(`DELETE FROM paw_queue WHERE item_id IN (SELECT id FROM items WHERE ${cond})`).bind(cutoff),
    db.prepare(`DELETE FROM items WHERE ${cond} RETURNING id`).bind(cutoff),
  ]);
  return (out[2] as { results?: unknown[] }).results?.length ?? 0;
}
