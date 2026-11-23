// APNs へのお知らせ（alert）プッシュ。作りは家族掲示板（~/work/kazoku-keijiban/worker/src/apns.ts）と同じ:
// - 認証は token-based（.p8 の ES256 で JWT を署名）。JWT は 20〜60 分ごとに作り直すきまりなので 50 分使い回す
// - 送る口は ApnsSender インターフェイスに切ってあり、テストではモックを差し込む（notify.ts）
// 家族掲示板との違い: ウィジェット用ではなく通常の通知（apns-push-type: alert・apns-topic: <bundle id>）。
// 宛先の環境（sandbox／本番）は端末ごとにアプリが申告したものを使う（devicectl で入れた開発署名は sandbox）

import type { Env } from "./env.ts";

export type ApnsEnvironment = "development" | "production";

export interface ApnsResult {
  status: number;
  /** APNs が返す理由（BadDeviceToken・Unregistered など）。成功なら undefined */
  reason?: string;
}

export interface ApnsSender {
  send(deviceToken: string, environment: ApnsEnvironment, payload: string): Promise<ApnsResult>;
}

export interface ApnsConfig {
  key: string; // .p8 の PEM
  keyId: string;
  teamId: string;
  bundleId: string;
}

export const APNS_HOST_PRODUCTION = "api.push.apple.com";
export const APNS_HOST_DEVELOPMENT = "api.sandbox.push.apple.com";
export const JWT_REUSE_SECONDS = 50 * 60;

/** env から設定を拾う。鍵が1つでも欠けていれば null（＝送らない） */
export function apnsConfig(env: Env): ApnsConfig | null {
  const key = env.APNS_KEY?.trim();
  const keyId = env.APNS_KEY_ID?.trim();
  const teamId = env.APNS_TEAM_ID?.trim();
  const bundleId = env.APNS_BUNDLE_ID?.trim();
  if (!key || !keyId || !teamId || !bundleId) return null;
  return { key, keyId, teamId, bundleId };
}

export function apnsHost(environment: ApnsEnvironment): string {
  return environment === "development" ? APNS_HOST_DEVELOPMENT : APNS_HOST_PRODUCTION;
}

export function b64url(data: ArrayBuffer | Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** .p8（PKCS#8 の PEM）を署名鍵に */
export async function importP8(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/** APNs の provider token（ES256 の JWT）。WebCrypto の ECDSA 署名は r||s（IEEE P1363）なので JWS の形そのまま */
export async function makeProviderToken(key: CryptoKey, keyId: string, teamId: string, issuedAt: number): Promise<string> {
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: teamId, iat: issuedAt }));
  const input = `${header}.${claims}`;
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  return `${input}.${b64url(sig)}`;
}

type FetchLike = (input: string, init: RequestInit) => Promise<Response>;

// isolate の中で JWT を使い回す（APNs は作り直しが頻繁すぎると TooManyProviderTokenUpdates を返す）
let cached: { cacheKey: string; token: string; issuedAt: number } | null = null;

export function resetTokenCacheForTest(): void {
  cached = null;
}

async function providerToken(cfg: ApnsConfig, nowSec: number): Promise<string> {
  const cacheKey = `${cfg.teamId}/${cfg.keyId}`;
  if (cached && cached.cacheKey === cacheKey && nowSec - cached.issuedAt < JWT_REUSE_SECONDS) return cached.token;
  const token = await makeProviderToken(await importP8(cfg.key), cfg.keyId, cfg.teamId, nowSec);
  cached = { cacheKey, token, issuedAt: nowSec };
  return token;
}

/** 本物の APNs へ送る口 */
export function httpApnsSender(cfg: ApnsConfig, fetchImpl: FetchLike = fetch, now: () => number = Date.now): ApnsSender {
  return {
    async send(deviceToken, environment, payload) {
      const jwt = await providerToken(cfg, Math.floor(now() / 1000));
      const res = await fetchImpl(`https://${apnsHost(environment)}/3/device/${deviceToken}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": cfg.bundleId,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "content-type": "application/json",
        },
        body: payload,
      });
      if (res.ok) return { status: res.status };
      let reason: string | undefined;
      try {
        reason = ((await res.json()) as { reason?: string }).reason;
      } catch {
        reason = undefined;
      }
      return { status: res.status, reason };
    },
  };
}
