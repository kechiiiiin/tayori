// 段階3: ポッドキャストの番組（feeds.kind = 'podcast'）とエピソード（items の enclosure つき）の読み書き。
// キュー・再生位置・自動追加の設定・ダウンロードは iPhone の中に持つ（ここには無い）。
// 番組の回は記事の「初回 20 件・既読 90 日で消す」を使わず、番組ごとに新しい順 PODCAST_MAX_EPISODES 回までを持つ
import { newest, type ParsedItem } from "./parse.ts";
import { encodeCursor } from "./store.ts";

/** 1番組で持つ回の上限（新しい順）。これより古い回は取得のたびに消す（コメントのある回は残す） */
export const PODCAST_MAX_EPISODES = 300;
export const EPISODE_PAGE_SIZE = 50;

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

/**
 * 取ってきた回を入れる。新しい順に PODCAST_MAX_EPISODES 回まで。控え（item_tombstones）は見ない。
 * もうある回は enclosure・長さ・題名・URL が変わったときだけ書き換える（記事から移した番組の回にも enclosure が埋まる）。
 * 上限より古い回は消す（コメントのある回は残す）。戻り値は新しく入った回の数
 */
export async function upsertEpisodes(db: D1Database, feedId: number, items: ParsedItem[], now: Date): Promise<number> {
  const seen = new Set<string>();
  const unique = items.filter((i) => (seen.has(i.guid) ? false : (seen.add(i.guid), true)));
  const keep = newest(unique, PODCAST_MAX_EPISODES);
  const before = await guids(db, feedId);
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
  const stmts: D1PreparedStatement[] = [];
  if (rows.length) {
    stmts.push(
      db
        .prepare(
          `INSERT INTO items (feed_id, guid, url, title, published_at, fetched_at, sort_at, enclosure_url, enclosure_type, duration_sec)
           SELECT ?1, json_extract(value, '$.guid'), json_extract(value, '$.url'), json_extract(value, '$.title'),
                  json_extract(value, '$.published_at'), ?2, json_extract(value, '$.sort_at'),
                  json_extract(value, '$.enclosure_url'), json_extract(value, '$.enclosure_type'), json_extract(value, '$.duration_sec')
             FROM json_each(?3) WHERE true
           ON CONFLICT (feed_id, guid) DO UPDATE SET
                  enclosure_url = excluded.enclosure_url,
                  enclosure_type = excluded.enclosure_type,
                  duration_sec = COALESCE(excluded.duration_sec, items.duration_sec),
                  title = excluded.title,
                  url = excluded.url
            WHERE items.enclosure_url IS NOT excluded.enclosure_url
               OR items.enclosure_type IS NOT excluded.enclosure_type
               OR (excluded.duration_sec IS NOT NULL AND items.duration_sec IS NOT excluded.duration_sec)
               OR items.title IS NOT excluded.title
               OR items.url IS NOT excluded.url`,
        )
        .bind(feedId, at, JSON.stringify(rows)),
    );
  }
  stmts.push(
    db
      .prepare(
        `DELETE FROM items WHERE feed_id = ?1 AND comment IS NULL
            AND id NOT IN (SELECT id FROM items WHERE feed_id = ?1 ORDER BY sort_at DESC, id DESC LIMIT ?2)`,
      )
      .bind(feedId, PODCAST_MAX_EPISODES),
  );
  await db.batch(stmts);
  const after = await guids(db, feedId);
  // 新しく入った数 = 前は無く、いまある回（上限で消えたものは数えない）
  return keep.filter((i) => !before.has(i.guid) && after.has(i.guid)).length;
}

async function guids(db: D1Database, feedId: number): Promise<Set<string>> {
  return new Set((await db.prepare("SELECT guid FROM items WHERE feed_id = ?").bind(feedId).all<{ guid: string }>()).results.map((r) => r.guid));
}

/** 記事のフィードを番組へ移す（カテゴリを外し、控えを消し、次の取得で条件なしに全文を取り直す） */
export async function convertToPodcast(db: D1Database, feedId: number): Promise<void> {
  await db.batch([
    db
      .prepare("UPDATE feeds SET kind = 'podcast', category_id = NULL, etag = NULL, last_modified = NULL WHERE id = ?")
      .bind(feedId),
    db.prepare("DELETE FROM item_tombstones WHERE feed_id = ?").bind(feedId),
    db.prepare("DELETE FROM paw_queue WHERE item_id IN (SELECT id FROM items WHERE feed_id = ?)").bind(feedId),
  ]);
}

export async function listPodcasts(db: D1Database): Promise<PodcastView[]> {
  const rows = (
    await db
      .prepare(
        `SELECT f.id, f.title, f.site_url, f.feed_url, f.image_url, f.last_fetched_at, f.last_error, f.created_at,
                COUNT(i.id) AS episodes, MAX(i.id) AS latest_episode_id, MAX(i.sort_at) AS latest_at
           FROM feeds f
           LEFT JOIN items i ON i.feed_id = f.id AND i.enclosure_url IS NOT NULL
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

const EPISODE_VIEW = `SELECT i.id, i.feed_id, f.title AS feed_title, f.image_url AS feed_image_url, i.title, i.url,
       i.published_at, i.sort_at, i.enclosure_url, i.enclosure_type, i.duration_sec
  FROM items i JOIN feeds f ON f.id = i.feed_id
 WHERE f.kind = 'podcast' AND i.enclosure_url IS NOT NULL`;

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
    where.push("i.feed_id = ?");
    args.push(q.feed);
  }
  const limit = Math.max(1, Math.min(q.limit ?? EPISODE_PAGE_SIZE, 200));
  if (q.afterId !== undefined) {
    where.push("i.id > ?");
    args.push(q.afterId);
    const sql = `${EPISODE_VIEW}${where.map((w) => " AND " + w).join("")} ORDER BY i.id ASC LIMIT ?`;
    const rows = (await db.prepare(sql).bind(...args, limit + 1).all<EpisodeView>()).results;
    const episodes = rows.slice(0, limit);
    // after_id の続きは最後の id を after_id に渡す
    return { episodes, next: rows.length > limit ? String(episodes[episodes.length - 1].id) : null };
  }
  if (q.before) {
    where.push("(i.sort_at < ? OR (i.sort_at = ? AND i.id < ?))");
    args.push(q.before.sort_at, q.before.sort_at, q.before.id);
  }
  const sql = `${EPISODE_VIEW}${where.map((w) => " AND " + w).join("")} ORDER BY i.sort_at DESC, i.id DESC LIMIT ?`;
  const rows = (await db.prepare(sql).bind(...args, limit + 1).all<EpisodeView>()).results;
  const episodes = rows.slice(0, limit);
  return { episodes, next: rows.length > limit ? encodeCursor(episodes[episodes.length - 1]) : null };
}
