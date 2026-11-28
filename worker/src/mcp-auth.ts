// /mcp（Access の外に出した MCP の口）の認証: Authorization: Bearer <token> を Worker secret MCP_TOKENS と照合する。
// MCP_TOKENS はカンマ区切り（前後の空白を除く・空要素は無視）。未設定・空なら全部拒否。32 文字未満のトークンは設定されていても無視。
// 失敗は 401 と {"error":"unauthorized"}。**WWW-Authenticate は付けない**（クライアントを OAuth へ誘導しないため）
import type { MiddlewareHandler } from "hono";
import type { AppEnv } from "./env.ts";

export const MCP_TOKEN_MIN_LENGTH = 32;

const enc = new TextEncoder();

/** SHA-256 にかけてから全バイトを比べる（長さも内容も漏らさない定数時間の比較） */
async function constantTimeEqual(a: string, b: string): Promise<boolean> {
  const [ha, hb] = await Promise.all([crypto.subtle.digest("SHA-256", enc.encode(a)), crypto.subtle.digest("SHA-256", enc.encode(b))]);
  const x = new Uint8Array(ha);
  const y = new Uint8Array(hb);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i]! ^ y[i]!;
  return diff === 0;
}

export function parseMcpTokens(raw: string | undefined): string[] {
  return (raw ?? "")
    .split(",")
    .map((t) => t.trim())
    .filter((t) => t.length >= MCP_TOKEN_MIN_LENGTH);
}

export const requireMcpToken: MiddlewareHandler<AppEnv> = async (c, next) => {
  const tokens = parseMcpTokens(c.env.MCP_TOKENS);
  const m = /^Bearer[ \t]+(\S+)$/i.exec(c.req.header("Authorization")?.trim() ?? "");
  const given = m?.[1] ?? "";
  // 全候補と必ず比べる（早期 return しない）
  let ok = false;
  for (const t of tokens) if (await constantTimeEqual(given, t)) ok = true;
  if (!ok || given.length < MCP_TOKEN_MIN_LENGTH) return c.json({ error: "unauthorized" }, 401);
  await next();
};
