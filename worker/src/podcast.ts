// 段階3: ポッドキャストの番組（feeds.kind = 'podcast'）とエピソード（episodes テーブル）の読み書き。
// キュー・再生位置・自動追加の設定・ダウンロードは iPhone の中に持つ（ここには無い）。
// 回は記事（items）とは別の表で、既読・コメント・控え・初回 20 件・既読 90 日の仕組みに乗らない。
// 番組の回は上限なしに全部持ち、フィードから消えた回も消さない（過去回を全部残す）
import type { ParsedItem } from "./parse.ts";
import { encodeCursor } from "./store.ts";

export const EPISODE_PAGE_SIZE = 30;
/** 1つの INSERT／UPDATE に JSON で渡す回の数（D1 の文字列・文の大きさの上限に掛からないよう分ける） */
export const EPISODE_WRITE_CHUNK = 200;

export interface PodcastView {
  id: number;
  title: string;
  site_url: string | null;
  feed_url: string;
  image_url: string | null;
  last_fetched_at: string | null;
  last_error: string | null;
  created_at: string;
  /** 再生できる回（enclosure のある回）の数 */
  episodes: number;
  /** いちばん大きいエピソードの id（アプリが「まだ見ていない回」を知るのに使う）。回が無ければ null */
  latest_episode_id: number | null;
  /** いちばん新しい回の sort_at。回が無ければ null */
  latest_at: string | null;
}

export interface EpisodeView {
  id: number;
  feed_id: number;
  feed_title: string;
  /** 番組のアートワーク（回ごとの画像は持たない） */
  feed_image_url: string | null;
  title: string;
  /** 回のページ（無い配信もある） */
  url: string | null;
  published_at: string | null;
  sort_at: string;
  enclosure_url: string;
  enclosure_type: string | null;
  duration_sec: number | null;
}

/** 回の詳細（GET /api/episodes/:id）。一覧には重いので載せない説明（HTML のまま）を足す */
export interface EpisodeDetail extends EpisodeView {
  description: string | null;
}

type EpisodeRow = {
  guid: string;
  url: string | null;
  title: string;
  published_at: string | null;
  sort_at: string;
  enclosure_url: string;
  enclosure_type: string | null;
  duration_sec: number | null;
  description: string | null;
};

function chunks<T>(xs: T[], n: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < xs.length; i += n) out.push(xs.slice(i, i + n));
  return out;
}

/**
 * 取ってきた回を入れる。音声のある回を上限なしに全部。フィードから消えた回は消さない。
 * もうある回は書き込まない（音声・長さ・題名・URL が変わった回と、説明がまだ NULL で今回は説明のある回だけ書き換える）。
 * 説明の中身の変化は見ない（毎回 50KB×回数を読み比べないため）。
 * 新しい回は古い順に入れる（id が配信順に増える）。戻り値は新しく入った回の数
 */
export async function upsertEpisodes(db: D1Database, feedId: number, items: ParsedItem[], now: Date): Promise<number> {
  const at = now.toISOString();
  const seen = new Set<string>();
  const rows: EpisodeRow[] = [];
  for (const i of items) {
    if (!i.enclosure_url || seen.has(i.guid)) continue;
    seen.add(i.guid);
    rows.push({
      guid: i.guid,
      url: i.url,
      title: i.title,
      published_at: i.published_at,
      sort_at: i.published_at && i.published_at <= at ? i.published_at : at,
      enclosure_url: i.enclosure_url,
      enclosure_type: i.enclosure_type ?? null,
      duration_sec: i.duration_sec ?? null,
      description: i.description ?? null,
    });
  }
  if (!rows.length) return 0;
  const known = new Map(
    (
      await db
        .prepare(
          "SELECT guid, url, title, enclosure_url, enclosure_type, duration_sec, description IS NULL AS no_description FROM episodes WHERE feed_id = ?",
        )
        .bind(feedId)
        .all<Omit<EpisodeRow, "published_at" | "sort_at" | "description"> & { no_description: number }>()
    ).results.map((r) => [r.guid, r]),
  );
  const fresh = rows.filter((r) => !known.has(r.guid)).sort((x, y) => (x.sort_at < y.sort_at ? -1 : x.sort_at > y.sort_at ? 1 : 0));
  const changed = rows.filter((r) => {
    const k = known.get(r.guid);
    return (
      !!k &&
      (k.enclosure_url !== r.enclosure_url ||
        k.enclosure_type !== r.enclosure_type ||
        k.title !== r.title ||
        k.url !== r.url ||
        (r.duration_sec !== null && Number(k.duration_sec) !== r.duration_sec) ||
        (r.description !== null && Number(k.no_description) === 1))
    );
  });
  const stmts: D1PreparedStatement[] = [];
  for (const part of chunks(fresh, EPISODE_WRITE_CHUNK)) {
    stmts.push(
      db
        .prepare(
          `INSERT OR IGNORE INTO episodes (feed_id, guid, url, title, published_at, fetched_at, sort_at, enclosure_url, enclosure_type, duration_sec, description)
           SELECT ?1, json_extract(value, '$.guid'), json_extract(value, '$.url'), json_extract(value, '$.title'),
                  json_extract(value, '$.published_at'), ?2, json_extract(value, '$.sort_at'),
                  json_extract(value, '$.enclosure_url'), json_extract(value, '$.enclosure_type'), json_extract(value, '$.duration_sec'),
                  json_extract(value, '$.description')
             FROM json_each(?3) ORDER BY key`,
        )
        .bind(feedId, at, JSON.stringify(part)),
    );
  }
  for (const part of chunks(changed, EPISODE_WRITE_CHUNK)) {
    stmts.push(
      db
        .prepare(
          `UPDATE episodes SET
                  enclosure_url = j.enclosure_url,
                  enclosure_type = j.enclosure_type,
                  duration_sec = COALESCE(j.duration_sec, episodes.duration_sec),
                  title = j.title,
                  url = j.url,
                  description = COALESCE(j.description, episodes.description)
             FROM (SELECT json_extract(value, '$.guid') AS guid, json_extract(value, '$.url') AS url, json_extract(value, '$.title') AS title,
                          json_extract(value, '$.enclosure_url') AS enclosure_url, json_extract(value, '$.enclosure_type') AS enclosure_type,
                          json_extract(value, '$.duration_sec') AS duration_sec, json_extract(value, '$.description') AS description
                     FROM json_each(?2)) AS j
            WHERE episodes.feed_id = ?1 AND episodes.guid = j.guid`,
        )
        .bind(feedId, JSON.stringify(part)),
    );
  }
  if (stmts.length) await db.batch(stmts);
  return fresh.length;
}

/**
 * 記事のフィードを番組へ移す（カテゴリを外し、次の取得で条件なしに全文を取り直す）。
 * 記事として入っていた回は items から消す（コメントのある回だけは残す・記事一覧には kind で出ない）
 */
export async function convertToPodcast(db: D1Database, feedId: number): Promise<void> {
  await db.batch([
    db
      .prepare("UPDATE feeds SET kind = 'podcast', category_id = NULL, etag = NULL, last_modified = NULL WHERE id = ?")
      .bind(feedId),
    db.prepare("DELETE FROM item_tombstones WHERE feed_id = ?").bind(feedId),
    db.prepare("DELETE FROM paw_queue WHERE item_id IN (SELECT id FROM items WHERE feed_id = ? AND comment IS NULL)").bind(feedId),
    db.prepare("DELETE FROM items WHERE feed_id = ? AND comment IS NULL").bind(feedId),
  ]);
}

export async function listPodcasts(db: D1Database): Promise<PodcastView[]> {
  const rows = (
    await db
      .prepare(
        `SELECT f.id, f.title, f.site_url, f.feed_url, f.image_url, f.last_fetched_at, f.last_error, f.created_at,
                COUNT(e.id) AS episodes, MAX(e.id) AS latest_episode_id, MAX(e.sort_at) AS latest_at
           FROM feeds f
           LEFT JOIN episodes e ON e.feed_id = f.id
          WHERE f.kind = 'podcast'
          GROUP BY f.id
          ORDER BY latest_at IS NULL, latest_at DESC, f.title COLLATE NOCASE, f.id`,
      )
      .all<PodcastView>()
  ).results;
  return rows.map((r) => ({
    ...r,
    episodes: Number(r.episodes),
    latest_episode_id: r.latest_episode_id == null ? null : Number(r.latest_episode_id),
  }));
}

export async function getPodcast(db: D1Database, id: number): Promise<PodcastView | null> {
  return (await listPodcasts(db)).find((p) => p.id === id) ?? null;
}

const EPISODE_VIEW = `SELECT e.id, e.feed_id, f.title AS feed_title, f.image_url AS feed_image_url, e.title, e.url,
       e.published_at, e.sort_at, e.enclosure_url, e.enclosure_type, e.duration_sec
  FROM episodes e JOIN feeds f ON f.id = e.feed_id`;

/** 1回の詳細（説明つき）。無ければ null */
export async function getEpisode(db: D1Database, id: number): Promise<EpisodeDetail | null> {
  const sql = `SELECT e.id, e.feed_id, f.title AS feed_title, f.image_url AS feed_image_url, e.title, e.url,
       e.published_at, e.sort_at, e.enclosure_url, e.enclosure_type, e.duration_sec, e.description
  FROM episodes e JOIN feeds f ON f.id = e.feed_id WHERE e.id = ?`;
  return (await db.prepare(sql).bind(id).first<EpisodeDetail>()) ?? null;
}

/**
 * エピソード一覧。
 * - ふだん: 新しい順（sort_at・id）。before で続き
 * - after_id: id がそれより大きい回を id の昇順で（アプリが新着を番組の設定に従ってキューへ入れるのに使う）
 * feed を渡せばその番組だけ
 */
export async function listEpisodes(
  db: D1Database,
  q: { feed?: number; before?: { sort_at: string; id: number }; afterId?: number; limit?: number },
): Promise<{ episodes: EpisodeView[]; next: string | null }> {
  const where: string[] = [];
  const args: (string | number)[] = [];
  if (q.feed !== undefined) {
    where.push("e.feed_id = ?");
    args.push(q.feed);
  }
  const limit = Math.max(1, Math.min(q.limit ?? EPISODE_PAGE_SIZE, 200));
  if (q.afterId !== undefined) {
    where.push("e.id > ?");
    args.push(q.afterId);
    const sql = `${EPISODE_VIEW}${where.length ? " WHERE " + where.join(" AND ") : ""} ORDER BY e.id ASC LIMIT ?`;
    const rows = (await db.prepare(sql).bind(...args, limit + 1).all<EpisodeView>()).results;
    const episodes = rows.slice(0, limit);
    // after_id の続きは最後の id を after_id に渡す
    return { episodes, next: rows.length > limit ? String(episodes[episodes.length - 1].id) : null };
  }
  if (q.before) {
    where.push("(e.sort_at < ? OR (e.sort_at = ? AND e.id < ?))");
    args.push(q.before.sort_at, q.before.sort_at, q.before.id);
  }
  const sql = `${EPISODE_VIEW}${where.length ? " WHERE " + where.join(" AND ") : ""} ORDER BY e.sort_at DESC, e.id DESC LIMIT ?`;
  const rows = (await db.prepare(sql).bind(...args, limit + 1).all<EpisodeView>()).results;
  const episodes = rows.slice(0, limit);
  return { episodes, next: rows.length > limit ? encodeCursor(episodes[episodes.length - 1]) : null };
}
