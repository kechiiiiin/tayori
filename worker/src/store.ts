// D1 の読み書き（カテゴリ・フィード・記事）。ネットワークには出ない（取りに行くのは fetcher.ts）
import { newest, type ParsedItem } from "./parse.ts";

export type ItemState = "unread" | "commented" | "all";
/** article = 記事（今までどおり）／podcast = ポッドキャストの番組（記事一覧・カテゴリの数には出ない） */
export type FeedKind = "article" | "podcast";

export function isKind(v: unknown): v is FeedKind {
  return v === "article" || v === "podcast";
}

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
  kind: FeedKind;
  category_id: number | null;
  title: string;
  site_url: string | null;
  feed_url: string;
  /** ポッドキャストの番組アートワーク（itunes:image）。無ければ null */
  image_url: string | null;
  last_fetched_at: string | null;
  last_error: string | null;
  /** 段階2: 既読にした記事を rururu へ送るキューに積むか（サイト画面の「rururu に送る」） */
  rururu_paw: boolean;
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
  kind: FeedKind;
  category_id: number | null;
  title: string;
  site_url: string | null;
  feed_url: string;
  image_url: string | null;
  etag: string | null;
  last_modified: string | null;
  last_fetched_at: string | null;
  last_error: string | null;
  rururu_paw: number;
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
        WHERE f.category_id IS NULL AND f.kind = 'article'`, // 番組（カテゴリなし）の items に残ったコメントつきの回を数えない
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

const FEED_VIEW = `SELECT f.id, f.kind, f.category_id, f.title, f.site_url, f.feed_url, f.image_url, f.last_fetched_at, f.last_error, f.rururu_paw, f.created_at,
       (SELECT COUNT(*) FROM items i WHERE i.feed_id = f.id AND i.read_at IS NULL) AS unread
  FROM feeds f`;

function feedView(r: FeedView): FeedView {
  return { ...r, rururu_paw: Number(r.rururu_paw) === 1, unread: Number(r.unread) };
}

/** kind を渡せばその種類だけ（GET /api/feeds の既定は article＝サイト画面に番組を出さない） */
export async function listFeeds(db: D1Database, kind?: FeedKind): Promise<FeedView[]> {
  const where = kind ? " WHERE f.kind = ?" : "";
  const stmt = db.prepare(`${FEED_VIEW}${where} ORDER BY f.title COLLATE NOCASE, f.id`);
  const rows = (await (kind ? stmt.bind(kind) : stmt).all<FeedView>()).results;
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
    kind?: FeedKind;
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
      `INSERT INTO feeds (kind, category_id, title, site_url, feed_url, image_url, etag, last_modified, last_fetched_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id`,
    )
    .bind(f.kind ?? "article", f.category_id, f.title, f.site_url, f.feed_url, f.image_url, f.etag, f.last_modified, at, at)
    .first<{ id: number }>();
  return Number(r!.id);
}

export async function setFeedCategory(db: D1Database, id: number, categoryId: number | null): Promise<boolean> {
  const r = await db.prepare("UPDATE feeds SET category_id = ? WHERE id = ?").bind(categoryId, id).run();
  return (r.meta?.changes ?? 0) > 0;
}

/**
 * 「rururu に送る」の切り替え。オンにしても過去の既読は積まない（オン以降に既読にしたものだけ）。
 * オフにしたら、そのサイトのまだ送っていないキュー行は外す（送った控えは残す）
 */
export async function setFeedRururuPaw(db: D1Database, id: number, on: boolean): Promise<boolean> {
  const r = await db.prepare("UPDATE feeds SET rururu_paw = ? WHERE id = ?").bind(on ? 1 : 0, id).run();
  if ((r.meta?.changes ?? 0) === 0) return false;
  if (!on) {
    await db
      .prepare("DELETE FROM paw_queue WHERE sent_at IS NULL AND item_id IN (SELECT id FROM items WHERE feed_id = ?)")
      .bind(id)
      .run();
  }
  return true;
}

/** 外す。記事（コメントごと）・番組の回・控え・paw_queue も消す */
export async function deleteFeed(db: D1Database, id: number): Promise<boolean> {
  if (!(await getFeedRow(db, id))) return false;
  await db.batch([
    db.prepare("DELETE FROM episodes WHERE feed_id = ?").bind(id),
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
 * D1 の束縛変数の上限（100）に掛からないよう、行は JSON 1つで渡して json_each で展開する。
 * 戻り値は新しく入れた記事（プッシュで知らせるものを選ぶのに使う）
 */
export async function insertItems(db: D1Database, feedId: number, items: ParsedItem[], now: Date, initial: boolean): Promise<ParsedItem[]> {
  const seen = new Set<string>();
  const unique = items.filter((i) => (seen.has(i.guid) ? false : (seen.add(i.guid), true)));
  if (!unique.length) return [];
  const known = new Set(
    (
      await db
        .prepare("SELECT guid FROM items WHERE feed_id = ?1 UNION SELECT guid FROM item_tombstones WHERE feed_id = ?1")
        .bind(feedId)
        .all<{ guid: string }>()
    ).results.map((r) => r.guid),
  );
  const fresh = unique.filter((i) => !known.has(i.guid));
  if (!fresh.length) return [];
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
    enclosure_url: i.enclosure_url ?? null,
    enclosure_type: i.enclosure_type ?? null,
    duration_sec: i.duration_sec ?? null,
  }));
  const stmts = [
    db
      .prepare(
        `INSERT OR IGNORE INTO items (feed_id, guid, url, title, published_at, fetched_at, sort_at, enclosure_url, enclosure_type, duration_sec)
         SELECT ?1, json_extract(value, '$.guid'), json_extract(value, '$.url'), json_extract(value, '$.title'),
                json_extract(value, '$.published_at'), ?2, json_extract(value, '$.sort_at'),
                json_extract(value, '$.enclosure_url'), json_extract(value, '$.enclosure_type'), json_extract(value, '$.duration_sec')
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
  return keep;
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
  // 番組の回は episodes にある。items に残る番組の回（0006 の移行でコメントがあって残した回）は記事一覧に出さない
  const where: string[] = ["f.kind = 'article'"];
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
  const sql = `${ITEM_VIEW} WHERE ${where.join(" AND ")} ORDER BY i.sort_at DESC, i.id DESC LIMIT ?`;
  const rows = (
    await db
      .prepare(sql)
      .bind(...args, limit + 1)
      .all<ItemView>()
  ).results;
  const items = rows.slice(0, limit);
  return { items, next: rows.length > limit ? encodeCursor(items[items.length - 1]) : null };
}

/** JST の日付（YYYY-MM-DD）→ その日の UTC の範囲 [from, to)。暦に無い日付・形違いは null */
export function jstDayRange(date: string): { from: string; to: string } | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  if (!m) return null;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const startUtc = Date.UTC(y, mo - 1, d) - 9 * 3600_000; // JST 0:00 = 前日の UTC 15:00
  const check = new Date(startUtc + 9 * 3600_000);
  if (check.getUTCFullYear() !== y || check.getUTCMonth() !== mo - 1 || check.getUTCDate() !== d) return null;
  return { from: new Date(startUtc).toISOString(), to: new Date(startUtc + 86400_000).toISOString() };
}

/** read_at が JST のその日に入る記事（read_at 昇順）。かけら帳の「思い出す材料」用 */
export async function listReadOn(db: D1Database, range: { from: string; to: string }): Promise<ItemView[]> {
  return (
    await db
      .prepare(`${ITEM_VIEW} WHERE i.read_at >= ? AND i.read_at < ? ORDER BY i.read_at ASC, i.id ASC LIMIT 500`)
      .bind(range.from, range.to)
      .all<ItemView>()
  ).results;
}

export async function getItem(db: D1Database, id: number): Promise<ItemView | null> {
  return db.prepare(`${ITEM_VIEW} WHERE i.id = ?`).bind(id).first<ItemView>();
}

/**
 * 既読にする（もう既読なら時刻は変えない）／戻す。
 * 既読にしたとき（未読→既読のときだけ）、記事のサイトが rururu_paw=1 なら paw_queue へ積む（item_id が主キーなので重ならない）。
 * 戻したら、まだ送っていないキュー行を外す（送った控えは残す＝もう一度既読にしても積み直さない）
 */
export async function setRead(db: D1Database, id: number, read: boolean, now: Date): Promise<ItemView | null> {
  if (!(await db.prepare("SELECT 1 AS x FROM items WHERE id = ?").bind(id).first())) return null;
  const at = now.toISOString();
  await (read
    ? db.batch([
        db
          .prepare(
            `INSERT OR IGNORE INTO paw_queue (item_id, queued_at)
             SELECT i.id, ?1 FROM items i JOIN feeds f ON f.id = i.feed_id
              WHERE i.id = ?2 AND i.read_at IS NULL AND f.rururu_paw = 1 AND f.kind = 'article'`,
          )
          .bind(at, id),
        db.prepare("UPDATE items SET read_at = COALESCE(read_at, ?) WHERE id = ?").bind(at, id),
      ])
    : db.batch([
        db.prepare("DELETE FROM paw_queue WHERE item_id = ? AND sent_at IS NULL").bind(id),
        db.prepare("UPDATE items SET read_at = NULL WHERE id = ?").bind(id),
      ]));
  return getItem(db, id);
}

// ---------------- rururu への paw キュー（段階2） ----------------

export interface PawQueueEntry {
  item_id: number;
  url: string | null;
  title: string;
  feed_id: number;
  feed_title: string;
  feed_url: string;
  site_url: string | null;
  /** 送る時点のコメント（items.comment をそのまま。無ければ null） */
  comment: string | null;
  read_at: string | null;
  queued_at: string;
}

export const MAX_SKIP_REASON = 200;

/** まだ送っていない・飛ばしていないものを積んだ順に */
export async function listPawQueue(db: D1Database): Promise<PawQueueEntry[]> {
  return (
    await db
      .prepare(
        `SELECT q.item_id, i.url, i.title, i.feed_id, f.title AS feed_title, f.feed_url, f.site_url, i.comment, i.read_at, q.queued_at
           FROM paw_queue q JOIN items i ON i.id = q.item_id JOIN feeds f ON f.id = i.feed_id
          WHERE q.sent_at IS NULL AND q.skipped_at IS NULL
          ORDER BY q.queued_at, q.item_id`,
      )
      .all<PawQueueEntry>()
  ).results;
}

/** rururu の item の id: 正の整数（数字の文字列も受ける） */
export function normalizeRururuItemId(v: unknown): number | null {
  if (typeof v === "number" && Number.isSafeInteger(v) && v > 0) return v;
  if (typeof v === "string" && /^[1-9]\d{0,15}$/.test(v.trim())) return Number(v.trim());
  return null;
}

export function normalizeSkipReason(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const s = v.replace(/\s+/g, " ").trim();
  return s && [...s].length <= MAX_SKIP_REASON ? s : null;
}

type PawMark = "ok" | "not_found" | "already_sent";

async function pawRow(db: D1Database, itemId: number) {
  return db.prepare("SELECT sent_at FROM paw_queue WHERE item_id = ?").bind(itemId).first<{ sent_at: string | null }>();
}

/** 送れた: rururu の item の id を控え、sent_at を入れる（飛ばしていたものでも送れたら送った扱い） */
export async function markPawSent(db: D1Database, itemId: number, rururuItemId: number, now: Date): Promise<PawMark> {
  const row = await pawRow(db, itemId);
  if (!row) return "not_found";
  if (row.sent_at) return "already_sent";
  await db
    .prepare("UPDATE paw_queue SET sent_at = ?, rururu_item_id = ?, skipped_at = NULL, skip_reason = NULL, error = NULL WHERE item_id = ?")
    .bind(now.toISOString(), rururuItemId, itemId)
    .run();
  return "ok";
}

/** 送らずに外す（rururu に記事が無い・もう paw 済み など）。もう一度呼べば理由を上書き */
export async function markPawSkipped(db: D1Database, itemId: number, reason: string, now: Date): Promise<PawMark> {
  const row = await pawRow(db, itemId);
  if (!row) return "not_found";
  if (row.sent_at) return "already_sent";
  await db.prepare("UPDATE paw_queue SET skipped_at = ?, skip_reason = ? WHERE item_id = ?").bind(now.toISOString(), reason, itemId).run();
  return "ok";
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

/** 既読になって PURGE_DAYS 日たち、コメントの無い記事を消す（guid は控えに残し、次の取得で戻らないように）。既読の social_posts も同じ日数で消す */
export async function purgeOld(db: D1Database, now: Date): Promise<number> {
  const cutoff = new Date(now.getTime() - PURGE_DAYS * 86400_000).toISOString();
  // 番組の回は episodes にあり、ここでは消さない（items に残る番組の回はコメントつきなので対象外）
  // rururu へまだ送っていない（飛ばしてもいない）記事は、送るまで残す
  const cond =
    "read_at IS NOT NULL AND read_at < ?1 AND comment IS NULL AND id NOT IN (SELECT item_id FROM paw_queue WHERE sent_at IS NULL AND skipped_at IS NULL)";
  const out = await db.batch([
    db.prepare(`INSERT OR IGNORE INTO item_tombstones (feed_id, guid, created_at) SELECT feed_id, guid, ?2 FROM items WHERE ${cond}`).bind(cutoff, now.toISOString()),
    db.prepare(`DELETE FROM paw_queue WHERE item_id IN (SELECT id FROM items WHERE ${cond})`).bind(cutoff),
    db.prepare(`DELETE FROM items WHERE ${cond} RETURNING id`).bind(cutoff),
    // 段階4: 既読の投稿も 90 日で消す（未読は残す・数は返り値に含めない）
    db.prepare("DELETE FROM social_posts WHERE read_at IS NOT NULL AND read_at < ?").bind(cutoff),
  ]);
  return (out[2] as { results?: unknown[] }).results?.length ?? 0;
}

// ---------------- 段階4: X・Instagram の投稿（social_posts・ボットから受け取る） ----------------

export type SocialPlatform = "x" | "instagram";

export function isPlatform(v: unknown): v is SocialPlatform {
  return v === "x" || v === "instagram";
}

/** 1回で受け取る投稿の上限（REST・MCP 共通） */
export const MAX_SOCIAL_POSTS = 50;
export const SOCIAL_PAGE_SIZE = 50;
export const MAX_SOCIAL_PAGE = 200;
/** known で返す post_id の上限と、since を省いたときに遡る日数 */
export const MAX_KNOWN_IDS = 2000;
export const KNOWN_DEFAULT_DAYS = 7;
const MAX_POST_TEXT = 30000;
const MAX_MEDIA = 20;
const MAX_URL = 2048;
const MAX_QUOTED_JSON = 50000;

/** 投稿の URL として受け付けるホスト（正規 URL でないものを弾く） */
const PLATFORM_HOSTS: Record<SocialPlatform, string[]> = {
  x: ["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com", "mobile.x.com"],
  instagram: ["instagram.com", "www.instagram.com"],
};

export interface SocialMedia {
  type: "image" | "video" | "gif";
  url: string;
}

export interface SocialPostInput {
  platform: SocialPlatform;
  post_id: string;
  url: string;
  author_name: string | null;
  author_handle: string;
  author_avatar_url: string | null;
  text: string;
  media: SocialMedia[];
  posted_at: string;
  like_count: number | null;
  repost_count: number | null;
  reply_count: number | null;
  view_count: number | null;
  quoted: Record<string, unknown> | null;
  source: string;
}

export interface SocialPostView extends SocialPostInput {
  id: number;
  fetched_at: string;
  read_at: string | null;
}

export interface SocialAddResult {
  inserted: number;
  skipped: number;
  rejected: { index: number; reason: string }[];
}

/** ISO 8601（日時＋タイムゾーン）→ UTC の toISOString。日付だけ・タイムゾーン無し・暦に無い日時は null */
export function normalizeIsoTime(v: unknown): string | null {
  if (typeof v !== "string") return null;
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,9})?)?(Z|[+-]\d{2}:?\d{2})$/.test(v)) return null;
  const t = Date.parse(v);
  return Number.isFinite(t) ? new Date(t).toISOString() : null;
}

function httpUrl(v: unknown, hosts?: string[]): string | null {
  if (typeof v !== "string" || v.length > MAX_URL) return null;
  try {
    const u = new URL(v);
    if (u.protocol !== "https:" && u.protocol !== "http:") return null;
    if (hosts && !hosts.includes(u.hostname.toLowerCase())) return null;
    return v;
  } catch {
    return null;
  }
}

function optText(v: unknown, max: number): string | null | undefined {
  if (v === undefined || v === null) return null;
  if (typeof v !== "string" || [...v].length > max) return undefined;
  return v.trim() ? v : null;
}

function optCount(v: unknown): number | null | undefined {
  if (v === undefined || v === null) return null;
  return typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : undefined;
}

/**
 * 1件を確かめて形をそろえる。不正なら理由（英語の短い文）を返す。
 * **text は改変しない**（trim も改行の直しもしない）。author_handle だけ先頭の @ を落とす
 */
export function normalizeSocialPost(v: unknown, defaultSource: string): SocialPostInput | string {
  if (!v || typeof v !== "object" || Array.isArray(v)) return "post must be an object";
  const p = v as Record<string, unknown>;
  if (!isPlatform(p.platform)) return 'platform must be "x" or "instagram"';
  const platform = p.platform;
  if (typeof p.post_id !== "string") return "post_id must be a string (send X ids as strings to keep all digits)";
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(p.post_id)) return "post_id must be 1-64 characters of A-Z a-z 0-9 _ -";
  const url = httpUrl(p.url, PLATFORM_HOSTS[platform]);
  if (!url) return `url must be the post's canonical https URL on ${PLATFORM_HOSTS[platform][0]}`;
  if (typeof p.author_handle !== "string") return "author_handle is required";
  const handle = p.author_handle.trim().replace(/^@/, "");
  if (!/^[A-Za-z0-9_.]{1,64}$/.test(handle)) return "author_handle must be the account name without spaces (e.g. kechiiiiin)";
  const authorName = optText(p.author_name, 200);
  if (authorName === undefined) return "author_name must be a string up to 200 characters";
  let avatar: string | null = null;
  if (p.author_avatar_url !== undefined && p.author_avatar_url !== null && p.author_avatar_url !== "") {
    avatar = httpUrl(p.author_avatar_url);
    if (!avatar) return "author_avatar_url must be an http(s) URL";
  }
  if (typeof p.text !== "string") return "text is required (use an empty string when the post has no text)";
  if ([...p.text].length > MAX_POST_TEXT) return `text must be up to ${MAX_POST_TEXT} characters`;
  const media: SocialMedia[] = [];
  if (p.media !== undefined && p.media !== null) {
    if (!Array.isArray(p.media) || p.media.length > MAX_MEDIA) return `media must be an array of up to ${MAX_MEDIA} items`;
    for (const [i, m] of p.media.entries()) {
      const o = m && typeof m === "object" && !Array.isArray(m) ? (m as Record<string, unknown>) : null;
      if (!o || (o.type !== "image" && o.type !== "video" && o.type !== "gif")) return `media[${i}].type must be "image", "video" or "gif"`;
      const mu = httpUrl(o.url);
      if (!mu) return `media[${i}].url must be an http(s) URL`;
      media.push({ type: o.type, url: mu });
    }
  }
  const postedAt = normalizeIsoTime(p.posted_at);
  if (!postedAt) return "posted_at must be ISO 8601 with a time zone (e.g. 2026-11-29T09:30:00Z)";
  const counts: Record<"like_count" | "repost_count" | "reply_count" | "view_count", number | null> = {
    like_count: null,
    repost_count: null,
    reply_count: null,
    view_count: null,
  };
  for (const k of Object.keys(counts) as (keyof typeof counts)[]) {
    const n = optCount(p[k]);
    if (n === undefined) return `${k} must be a non-negative integer or null`;
    counts[k] = n;
  }
  let quoted: Record<string, unknown> | null = null;
  if (p.quoted !== undefined && p.quoted !== null) {
    if (typeof p.quoted !== "object" || Array.isArray(p.quoted)) return "quoted must be an object or null";
    if (JSON.stringify(p.quoted).length > MAX_QUOTED_JSON) return "quoted is too large";
    quoted = p.quoted as Record<string, unknown>;
  }
  let source = defaultSource;
  if (p.source !== undefined && p.source !== null && p.source !== "") {
    if (typeof p.source !== "string" || !/^[A-Za-z0-9_.-]{1,50}$/.test(p.source)) return "source must be a short name like grok-bot";
    source = p.source;
  }
  return {
    platform,
    post_id: p.post_id,
    url,
    author_name: authorName,
    author_handle: handle,
    author_avatar_url: avatar,
    text: p.text,
    media,
    posted_at: postedAt,
    ...counts,
    quoted,
    source,
  };
}

/**
 * 投稿の配列を入れる（REST・MCP 共通）。配列でない・上限超えは "bad_posts"／"too_many_posts"（何も入れない）。
 * 不正な行だけ理由つきで弾き、正しい行は入れる。(platform, post_id) が既にあれば skipped（同じ要求の中の重複も）
 */
export async function addSocialPosts(
  db: D1Database,
  input: unknown,
  now: Date,
  defaultSource: string,
): Promise<SocialAddResult | "bad_posts" | "too_many_posts"> {
  if (!Array.isArray(input)) return "bad_posts";
  if (input.length > MAX_SOCIAL_POSTS) return "too_many_posts";
  const rejected: SocialAddResult["rejected"] = [];
  const ok: SocialPostInput[] = [];
  input.forEach((v, index) => {
    const r = normalizeSocialPost(v, defaultSource);
    if (typeof r === "string") rejected.push({ index, reason: r });
    else ok.push(r);
  });
  if (ok.length === 0) return { inserted: 0, skipped: 0, rejected };
  const fetchedAt = now.toISOString();
  const out = await db.batch(
    ok.map((p) =>
      db
        .prepare(
          `INSERT INTO social_posts (platform, post_id, url, author_name, author_handle, author_avatar_url, text, media, posted_at,
             like_count, repost_count, reply_count, view_count, quoted, source, fetched_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT (platform, post_id) DO NOTHING RETURNING id`,
        )
        .bind(
          p.platform,
          p.post_id,
          p.url,
          p.author_name,
          p.author_handle,
          p.author_avatar_url,
          p.text,
          JSON.stringify(p.media),
          p.posted_at,
          p.like_count,
          p.repost_count,
          p.reply_count,
          p.view_count,
          p.quoted === null ? null : JSON.stringify(p.quoted),
          p.source,
          fetchedAt,
        ),
    ),
  );
  const inserted = out.filter((r) => ((r as { results?: unknown[] }).results?.length ?? 0) > 0).length;
  return { inserted, skipped: ok.length - inserted, rejected };
}

interface SocialRow extends Omit<SocialPostView, "media" | "quoted"> {
  media: string;
  quoted: string | null;
}

function socialView(r: SocialRow): SocialPostView {
  const parse = <T>(s: string | null, fallback: T): T => {
    if (s === null) return fallback;
    try {
      return JSON.parse(s) as T;
    } catch {
      return fallback;
    }
  };
  return { ...r, media: parse<SocialMedia[]>(r.media, []), quoted: parse<Record<string, unknown> | null>(r.quoted, null) };
}

/** 投稿の一覧（新しい順）。before は posted_at（それより前）か next の値（posted_at|id） */
export async function listSocialPosts(
  db: D1Database,
  q: { platform?: SocialPlatform; before?: { posted_at: string; id: number | null }; limit?: number },
): Promise<{ posts: SocialPostView[]; next: string | null }> {
  const limit = Math.min(Math.max(q.limit ?? SOCIAL_PAGE_SIZE, 1), MAX_SOCIAL_PAGE);
  const where: string[] = [];
  const args: (string | number)[] = [];
  if (q.platform) {
    where.push("platform = ?");
    args.push(q.platform);
  }
  if (q.before) {
    if (q.before.id === null) {
      where.push("posted_at < ?");
      args.push(q.before.posted_at);
    } else {
      where.push("(posted_at < ? OR (posted_at = ? AND id < ?))");
      args.push(q.before.posted_at, q.before.posted_at, q.before.id);
    }
  }
  const { results } = await db
    .prepare(
      `SELECT id, platform, post_id, url, author_name, author_handle, author_avatar_url, text, media, posted_at,
         like_count, repost_count, reply_count, view_count, quoted, source, fetched_at, read_at
       FROM social_posts ${where.length ? "WHERE " + where.join(" AND ") : ""}
       ORDER BY posted_at DESC, id DESC LIMIT ?`,
    )
    .bind(...args, limit + 1)
    .all<SocialRow>();
  const posts = results.slice(0, limit).map(socialView);
  const last = posts[posts.length - 1];
  return { posts, next: results.length > limit && last ? `${last.posted_at}|${last.id}` : null };
}

/** before の値: ISO 8601 の日時か、一覧の next（posted_at|id）。不正は null */
export function decodeSocialBefore(s: string): { posted_at: string; id: number | null } | null {
  const m = /^(.+)\|(\d{1,15})$/.exec(s);
  const t = normalizeIsoTime(m ? m[1] : s);
  if (!t) return null;
  return { posted_at: t, id: m ? Number(m[2]) : null };
}

/** ボットの重複よけ: since（posted_at がそれ以降）の post_id を新しい順に。since を省けば直近 KNOWN_DEFAULT_DAYS 日 */
export async function listKnownPostIds(
  db: D1Database,
  platform: SocialPlatform,
  since: string | undefined,
  now: Date,
): Promise<{ platform: SocialPlatform; since: string; post_ids: string[] }> {
  const from = since ?? new Date(now.getTime() - KNOWN_DEFAULT_DAYS * 86400_000).toISOString();
  const { results } = await db
    .prepare("SELECT post_id FROM social_posts WHERE platform = ? AND posted_at >= ? ORDER BY posted_at DESC, id DESC LIMIT ?")
    .bind(platform, from, MAX_KNOWN_IDS)
    .all<{ post_id: string }>();
  return { platform, since: from, post_ids: results.map((r) => r.post_id) };
}
