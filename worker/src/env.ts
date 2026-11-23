import type { Sekisho } from "./auth.ts";

export interface Env {
  DB: D1Database;

  // ---- 認証（Access のサービストークン。JWT の検証は関所 sekisho に聞く・auth.ts） ----
  /** 関所への Service Binding。未設定なら全員 401 */
  SEKISHO?: Sekisho;
  /** Access アプリ tayori の AUD タグ（secret）。空なら全員 401 */
  CF_ACCESS_AUD?: string;
  /** 通すサービストークンの Client ID（カンマ区切り・secret）。**空なら1本も通さない** */
  ACCESS_SERVICE_CLIENT_IDS?: string;

  // ---- フィードの取得（vars） ----
  /** cron 1回で取りに行くフィードの数（古い順）。Workers Free の subrequest 50 に収めるため。既定 40 */
  FETCH_PER_RUN?: string;

  // ---- APNs（「メイン」の新着のプッシュ）。鍵が揃っていなければ送らない（家族掲示板と同じ secret 名） ----
  /** .p8 の中身（PEM・secret） */
  APNS_KEY?: string;
  /** 鍵の Key ID（secret） */
  APNS_KEY_ID?: string;
  /** Apple Developer の Team ID（secret） */
  APNS_TEAM_ID?: string;
  /** アプリの bundle id（vars）。apns-topic になる */
  APNS_BUNDLE_ID?: string;

  /** ローカル開発の迂回。ビルド時定数と localhost が揃わないと効かない（auth.ts） */
  DEV_BYPASS_AUTH?: string;
}

export type AppEnv = { Bindings: Env; Variables: { principal: string } };
