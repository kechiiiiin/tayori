// 「メイン」の新着をプッシュで知らせる。
//
// 鳴らすのは: 名前が「メイン」のカテゴリ（iOS の起動時の絞り込みと同じ判定）のサイトで、
//   - 取得（cron・「いますぐ」）で**新しく取り込まれた**記事（初めて足したときの取り込みは鳴らさない）
//   - published_at が取得時刻から NOTIFY_MAX_AGE_MS 以内（古い記事の一括取り込みで鳴らさない。日付の無い記事も鳴らさない）
//   - 1回の取得で1サイト NOTIFY_MAX_PER_FEED 通まで（新しい順）、cron 1回で NOTIFY_MAX_PER_RUN 通まで
// 1記事につき登録済みで alerts=1（アプリの「通知」がオン）の端末それぞれへ1通。本文は「サイト名」（題）＋「記事の題名」（本文）。タップで記事を開く（item_id）
//
// もう一つ、ポッドキャストの新しい回が入った cron では、登録済みの全端末（alerts に関係なく）へサイレントプッシュ（background）を1通ずつ。
// アプリが裏で起きて新着を取り、キューへの自動追加とダウンロードを始める（ios/App/Push.swift）
import type { ApnsEnvironment, ApnsPushType, ApnsSender } from "./apns.ts";
import type { ParsedItem } from "./parse.ts";

export const NOTIFY_CATEGORY_NAME = "メイン";
export const NOTIFY_MAX_AGE_MS = 24 * 3600_000;
export const NOTIFY_MAX_PER_FEED = 3;
/** cron 1回の上限（Workers Free の subrequest 50 を APNs で食いつぶさないように） */
export const NOTIFY_MAX_PER_RUN = 10;

export interface Notice {
  item_id: number;
  feed_id: number;
  feed_title: string;
  title: string;
  url: string | null;
  published_at: string;
}

/** 新しく入った記事から、知らせるものを選ぶ（メインのサイトでなければ空） */
export async function pickNotices(db: D1Database, feedId: number, inserted: ParsedItem[], now: Date): Promise<Notice[]> {
  if (!inserted.length) return [];
  const feed = await db
    .prepare("SELECT f.title, c.name AS category FROM feeds f JOIN categories c ON c.id = f.category_id WHERE f.id = ?")
    .bind(feedId)
    .first<{ title: string; category: string }>();
  if (!feed || feed.category !== NOTIFY_CATEGORY_NAME) return [];
  const t = now.getTime();
  const recent = inserted
    .filter((i) => {
      if (!i.published_at) return false;
      const p = Date.parse(i.published_at);
      // 少し先の日付（時計のずれ）は許す。遠い未来の日付は信用しない
      return t - p <= NOTIFY_MAX_AGE_MS && p - t <= 3600_000;
    })
    .sort((a, b) => (a.published_at! < b.published_at! ? 1 : a.published_at! > b.published_at! ? -1 : 0))
    .slice(0, NOTIFY_MAX_PER_FEED);
  if (!recent.length) return [];
  const ids = (
    await db
      .prepare("SELECT id, guid FROM items WHERE feed_id = ?1 AND guid IN (SELECT value FROM json_each(?2))")
      .bind(feedId, JSON.stringify(recent.map((i) => i.guid)))
      .all<{ id: number; guid: string }>()
  ).results;
  const byGuid = new Map(ids.map((r) => [r.guid, Number(r.id)]));
  return recent.flatMap((i) => {
    const id = byGuid.get(i.guid);
    return id === undefined
      ? []
      : [{ item_id: id, feed_id: feedId, feed_title: feed.title, title: i.title, url: i.url, published_at: i.published_at! }];
  });
}

export function noticePayload(n: Notice): string {
  return JSON.stringify({
    aps: {
      alert: { title: n.feed_title, body: n.title },
      sound: "default",
      "thread-id": `feed-${n.feed_id}`,
    },
    item_id: n.item_id,
    url: n.url,
  });
}

// ---------------- 端末 ----------------

export interface DeviceRow {
  token: string;
  environment: ApnsEnvironment;
}

/** サイレントプッシュの中身（新着を取りに行かせるだけ・音も表示もなし） */
export const WAKEUP_PAYLOAD = JSON.stringify({ aps: { "content-available": 1 } });

/** APNs の端末トークン（16進）。小文字にそろえる。だめなら null */
export function normalizeToken(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const t = raw.trim().toLowerCase();
  return /^[0-9a-f]{16,400}$/.test(t) && t.length % 2 === 0 ? t : null;
}

export function normalizeEnvironment(raw: unknown): ApnsEnvironment | null {
  if (raw === undefined || raw === null) return "production";
  return raw === "development" || raw === "production" ? raw : null;
}

/** alerts: 真偽（省略は true）。それ以外は null */
export function normalizeAlerts(raw: unknown): boolean | null {
  if (raw === undefined || raw === null) return true;
  return typeof raw === "boolean" ? raw : null;
}

/** alerts = false はお知らせ（alert）を送らない端末（サイレントプッシュは送る） */
export async function upsertDevice(db: D1Database, token: string, environment: ApnsEnvironment, now: Date, alerts = true): Promise<void> {
  await db
    .prepare(
      `INSERT INTO device_tokens (token, environment, alerts, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?4)
       ON CONFLICT (token) DO UPDATE SET environment = excluded.environment, alerts = excluded.alerts, updated_at = excluded.updated_at`,
    )
    .bind(token, environment, alerts ? 1 : 0, now.toISOString())
    .run();
}

export async function deleteDevice(db: D1Database, token: string): Promise<boolean> {
  const r = await db.prepare("DELETE FROM device_tokens WHERE token = ?").bind(token).run();
  return (r.meta?.changes ?? 0) > 0;
}

/** alertsOnly = お知らせを受け取る端末（alerts=1）だけ */
export async function listDevices(db: D1Database, opts: { alertsOnly?: boolean } = {}): Promise<DeviceRow[]> {
  const where = opts.alertsOnly ? " WHERE alerts = 1" : "";
  return (await db.prepare(`SELECT token, environment FROM device_tokens${where} ORDER BY token`).all<DeviceRow>()).results;
}

/** 送らなくなる応答（アプリを消した・トークンがこのアプリ／環境のものでない） */
function isDeadToken(status: number, reason: string | undefined): boolean {
  return status === 410 || reason === "BadDeviceToken" || reason === "Unregistered" || reason === "DeviceTokenNotForTopic";
}

/** 1通を端末たちへ。死んだトークンは dead に足す（送らない）。成功した数を返す */
async function sendToDevices(sender: ApnsSender, devices: DeviceRow[], payload: string, pushType: ApnsPushType, dead: Set<string>): Promise<number> {
  let sent = 0;
  await Promise.all(
    devices
      .filter((d) => !dead.has(d.token))
      .map(async (d) => {
        try {
          const r = await sender.send(d.token, d.environment, payload, pushType);
          if (r.status >= 200 && r.status < 300) sent++;
          else if (isDeadToken(r.status, r.reason)) dead.add(d.token);
          else console.warn(`apns(${pushType}): ${r.status} ${r.reason ?? ""}`);
        } catch (e) {
          console.warn(`apns(${pushType}): ` + (e instanceof Error ? e.name : "error"));
        }
      }),
  );
  return sent;
}

/** 知らせを alerts=1 の端末へ。sender が無ければ（鍵が無い）送らない。死んだトークンは台帳から消す */
export async function sendNotices(db: D1Database, notices: Notice[], sender: ApnsSender | null | undefined, limit = NOTIFY_MAX_PER_RUN) {
  const list = notices.slice(0, limit);
  if (!sender || !list.length) return { sent: 0, notices: list.length };
  const devices = await listDevices(db, { alertsOnly: true });
  const dead = new Set<string>();
  let sent = 0;
  for (const n of list) sent += await sendToDevices(sender, devices, noticePayload(n), "alert", dead);
  for (const t of dead) await deleteDevice(db, t);
  return { sent, notices: list.length };
}

/** サイレントプッシュを登録済みの全端末へ1通ずつ（alerts に関係なく）。死んだトークンは台帳から消す */
export async function sendWakeups(db: D1Database, sender: ApnsSender | null | undefined): Promise<number> {
  if (!sender) return 0;
  const devices = await listDevices(db);
  if (!devices.length) return 0;
  const dead = new Set<string>();
  const sent = await sendToDevices(sender, devices, WAKEUP_PAYLOAD, "background", dead);
  for (const t of dead) await deleteDevice(db, t);
  return sent;
}
