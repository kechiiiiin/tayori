// 段階4の小さな試し: Grok Bot などのボットが投稿を届ける MCP の口（POST /api/mcp）。
// Streamable HTTP の「状態を持たない」版を手書きする: 1回の POST に JSON-RPC 2.0 のメッセージ1つ、答えは application/json で1つ
// （SSE・セッション ID は使わない）。通知・応答（id の無いもの・result／error だけのもの）は 202 で本文なし。
// 認証は app.ts の requireAccess（Access のサービストークン）の内側。ここでは確かめない
import type { Context } from "hono";
import type { AppEnv } from "./env.ts";
import {
  addSocialPosts,
  isPlatform,
  listKnownPostIds,
  MAX_SOCIAL_POSTS,
  normalizeIsoTime,
} from "./store.ts";

/** 応じられる版。要求がこのどれかならそれを返し、知らない版なら DEFAULT_PROTOCOL_VERSION を返す */
export const SUPPORTED_PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
export const DEFAULT_PROTOCOL_VERSION = "2025-06-18";
export const SERVER_INFO = { name: "tayori", version: "0.1.0" };
/** MCP 経由で入れた投稿の source の既定（行に source があればそちら） */
export const MCP_DEFAULT_SOURCE = "mcp";
/** /mcp（Bearer の口）経由の既定 */
export const MCP_BEARER_DEFAULT_SOURCE = "grok-bot";

type Id = string | number | null;

const postItemSchema = {
  type: "object",
  description: "1件の投稿。本文（text）は取得したまま一字も改変しない（要約・翻訳・整形・絵文字や改行の削除をしない）",
  properties: {
    platform: { type: "string", enum: ["x", "instagram"], description: '投稿のある場所。"x" か "instagram" のどちらか' },
    post_id: {
      type: "string",
      pattern: "^[A-Za-z0-9_-]{1,64}$",
      description: "その場所での投稿の ID。X は status の数字（桁を落とさないよう必ず文字列で）、Instagram は /p/ や /reel/ の後ろの shortcode",
    },
    url: {
      type: "string",
      format: "uri",
      description: "投稿の正規 URL（例 https://x.com/<handle>/status/<id>・https://www.instagram.com/p/<shortcode>/）。検索結果やリダイレクトの URL ではなく投稿そのもの",
    },
    author_handle: { type: "string", description: "投稿者のアカウント名（@ は付けても付けなくてもよい）" },
    author_name: { type: ["string", "null"], description: "投稿者の表示名（任意）" },
    author_avatar_url: { type: ["string", "null"], format: "uri", description: "投稿者のアイコン画像の URL（任意）" },
    text: { type: "string", description: "本文。取得したままを改変せずに入れる。本文が無い投稿は空文字" },
    media: {
      type: "array",
      maxItems: 20,
      description: "添付の画像・動画（任意・無ければ空配列か省略）",
      items: {
        type: "object",
        properties: {
          type: { type: "string", enum: ["image", "video", "gif"] },
          url: { type: "string", format: "uri" },
        },
        required: ["type", "url"],
        additionalProperties: false,
      },
    },
    posted_at: {
      type: "string",
      format: "date-time",
      description: "投稿日時。ISO 8601 でタイムゾーンつき（例 2026-11-29T09:30:00Z・2026-11-29T18:30:00+09:00）",
    },
    like_count: { type: ["integer", "null"], minimum: 0, description: "いいねの数（分からなければ null か省略）" },
    repost_count: { type: ["integer", "null"], minimum: 0, description: "リポストの数（任意）" },
    reply_count: { type: ["integer", "null"], minimum: 0, description: "返信の数（任意）" },
    view_count: { type: ["integer", "null"], minimum: 0, description: "表示回数（任意）" },
    quoted: {
      type: ["object", "null"],
      description: "引用元の投稿（任意）。同じ形のオブジェクト（post_id・url・author_handle・text・posted_at など）",
    },
    source: { type: "string", pattern: "^[A-Za-z0-9_.-]{1,50}$", description: '送り手の名前（例 "grok-bot"・省略時は "mcp"）' },
  },
  required: ["platform", "post_id", "url", "author_handle", "text", "posted_at"],
  additionalProperties: false,
} as const;

export const TOOLS = [
  {
    name: "add_posts",
    title: "投稿を音沙汰へ送る",
    description:
      `X・Instagram の投稿を音沙汰（tayori）に保存する。1回に ${MAX_SOCIAL_POSTS} 件まで。` +
      "本文は改変しない（要約・翻訳・整形をしない）。url は投稿の正規 URL。posted_at は ISO 8601（タイムゾーンつき）。platform は x か instagram。" +
      "既にある投稿（platform と post_id が同じ）は飛ばされるだけなので、送り直してよい。" +
      "結果は JSON で { inserted, skipped, rejected: [{ index, reason }] }。rejected の行は直して送り直す。" +
      "送る前に list_known_post_ids で既にある post_id を除くと無駄がない",
    inputSchema: {
      type: "object",
      properties: {
        posts: { type: "array", minItems: 1, maxItems: MAX_SOCIAL_POSTS, items: postItemSchema, description: "送る投稿の配列" },
      },
      required: ["posts"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "list_known_post_ids",
    title: "音沙汰にある投稿の ID",
    description:
      "音沙汰（tayori）に既にある投稿の post_id を新しい順に返す（重複よけ）。platform は x か instagram。" +
      "since（ISO 8601）を渡すと投稿日時がそれ以降のものだけ、省くと直近7日。結果は JSON で { platform, since, post_ids }",
    inputSchema: {
      type: "object",
      properties: {
        platform: { type: "string", enum: ["x", "instagram"], description: '"x" か "instagram"' },
        since: { type: "string", format: "date-time", description: "この日時以降に投稿されたものだけ（任意・ISO 8601・タイムゾーンつき）" },
      },
      required: ["platform"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
];

function rpcResult(id: Id, result: unknown) {
  return { jsonrpc: "2.0" as const, id, result };
}

function rpcError(id: Id, code: number, message: string) {
  return { jsonrpc: "2.0" as const, id, error: { code, message } };
}

function toolText(value: unknown, isError = false) {
  return { content: [{ type: "text", text: JSON.stringify(value) }], isError };
}

function isId(v: unknown): v is string | number {
  return typeof v === "string" || (typeof v === "number" && Number.isFinite(v));
}

async function callTool(c: Context<AppEnv>, name: string, args: Record<string, unknown>, now: Date, defaultSource: string) {
  if (name === "add_posts") {
    const r = await addSocialPosts(c.env.DB, args.posts, now, defaultSource);
    if (r === "bad_posts") return toolText({ error: "bad_posts", message: "posts must be an array of post objects" }, true);
    if (r === "too_many_posts") return toolText({ error: "too_many_posts", message: `send at most ${MAX_SOCIAL_POSTS} posts per call` }, true);
    // 弾いた行があれば isError（入った行は入っている・数は本文に）
    return toolText(r, r.rejected.length > 0);
  }
  // list_known_post_ids
  if (!isPlatform(args.platform)) return toolText({ error: "bad_platform", message: 'platform must be "x" or "instagram"' }, true);
  let since: string | undefined;
  if (args.since !== undefined && args.since !== null && args.since !== "") {
    const t = normalizeIsoTime(args.since);
    if (!t) return toolText({ error: "bad_since", message: "since must be ISO 8601 with a time zone" }, true);
    since = t;
  }
  return toolText(await listKnownPostIds(c.env.DB, args.platform, since, now));
}

/** POST /api/mcp の本体 */
export async function handleMcp(c: Context<AppEnv>, now: Date, defaultSource: string = MCP_DEFAULT_SOURCE): Promise<Response> {
  let msg: unknown;
  try {
    msg = JSON.parse(await c.req.text());
  } catch {
    return c.json(rpcError(null, -32700, "Parse error"), 400);
  }
  if (!msg || typeof msg !== "object" || Array.isArray(msg)) return c.json(rpcError(null, -32600, "Invalid Request: send one JSON-RPC message"), 400);
  const m = msg as Record<string, unknown>;
  if (m.jsonrpc !== "2.0") return c.json(rpcError(isId(m.id) ? m.id : null, -32600, "Invalid Request"), 400);

  // 通知（id なし）・クライアントからの応答（method なし）は受け取るだけ
  if (typeof m.method !== "string") return c.body(null, 202);
  if (m.id === undefined) return c.body(null, 202);
  if (!isId(m.id)) return c.json(rpcError(null, -32600, "Invalid Request: bad id"), 400);
  const id = m.id;
  const params = m.params && typeof m.params === "object" && !Array.isArray(m.params) ? (m.params as Record<string, unknown>) : {};

  switch (m.method) {
    case "initialize": {
      const requested = params.protocolVersion;
      const protocolVersion = typeof requested === "string" && SUPPORTED_PROTOCOL_VERSIONS.includes(requested) ? requested : DEFAULT_PROTOCOL_VERSION;
      return c.json(
        rpcResult(id, {
          protocolVersion,
          capabilities: { tools: { listChanged: false } },
          serverInfo: SERVER_INFO,
          instructions:
            "音沙汰（tayori）へ X・Instagram の投稿を届ける口。list_known_post_ids で既にある post_id を確かめ、新しい投稿だけを add_posts で送る。本文は改変しない",
        }),
      );
    }
    case "ping":
      return c.json(rpcResult(id, {}));
    case "tools/list":
      return c.json(rpcResult(id, { tools: TOOLS }));
    case "tools/call": {
      const name = params.name;
      if (typeof name !== "string" || !TOOLS.some((t) => t.name === name)) return c.json(rpcError(id, -32602, `Unknown tool: ${String(name)}`));
      const args = params.arguments;
      if (args !== undefined && (args === null || typeof args !== "object" || Array.isArray(args))) {
        return c.json(rpcResult(id, toolText({ error: "bad_arguments", message: "arguments must be an object" }, true)));
      }
      return c.json(rpcResult(id, await callTool(c, name, (args ?? {}) as Record<string, unknown>, now, defaultSource)));
    }
    default:
      return c.json(rpcError(id, -32601, `Method not found: ${m.method}`));
  }
}
