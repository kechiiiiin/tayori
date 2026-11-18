#!/usr/bin/env node
// rururu で購読しているチャンネルを便りへ流し込む（一度きり・rururu は読むだけ）。
//
//   node scripts/import-rururu.mjs --dry-run          件数と一覧だけ出す（便りには送らない）
//   node scripts/import-rururu.mjs                    本番（https://tayori.kechiiiiin.com）へ POST /api/feeds
//   TAYORI_URL=http://127.0.0.1:8792 node scripts/import-rururu.mjs   ローカルの wrangler dev へ（認証なし）
//
// 認証:
//   - rururu: ~/.local/bin/rururu（CLI）が保存している App Password（~/.config/rururu/config.json の
//     profiles.<名前>.app_password。既定は "default" のプロファイル・--profile で変えられる）を読み、
//     Authorization: Bearer で GraphQL に送る。**値は表示・ログ出力・別ファイルへの保存をしない**
//   - 便り: キーチェーン tayori-token（client-id / client-secret）の Access サービストークン
//
// 足したサイトはすべて「未分類」に入る（カテゴリはあとでアプリから分ける）。もう購読しているものは飛ばされる。
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const profileArg = args.includes("--profile") ? args[args.indexOf("--profile") + 1] : process.env.RURURU_PROFILE;
const TAYORI_URL = (process.env.TAYORI_URL ?? "https://tayori.kechiiiiin.com").replace(/\/$/, "");

const QUERY = `query { viewer { subscriptions { channel { title feedUrl siteUrl } } } }`;

function rururuAuth() {
  const path = join(homedir(), ".config", "rururu", "config.json");
  const conf = JSON.parse(readFileSync(path, "utf8"));
  const name = profileArg || conf.default;
  const p = conf.profiles?.[name];
  if (!p || typeof p.app_password !== "string" || !p.app_password) {
    throw new Error(`rururu のプロファイル「${name}」に App Password がありません（rururu auth で入れてください）`);
  }
  return { endpoint: p.endpoint || "https://rururu.app/graphql", password: p.app_password };
}

async function fetchSubscriptions() {
  const { endpoint, password } = rururuAuth();
  const res = await fetch(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${password}` },
    body: JSON.stringify({ query: QUERY }),
  });
  if (!res.ok) throw new Error(`rururu: HTTP ${res.status}`);
  const j = await res.json();
  if (j.errors?.length) throw new Error("rururu: " + j.errors.map((e) => e.message).join(" / "));
  const subs = j.data?.viewer?.subscriptions;
  if (!Array.isArray(subs)) throw new Error("rururu: viewer.subscriptions を読めませんでした");
  return subs
    .map((s) => s?.channel)
    .filter(Boolean)
    .map((c) => ({ title: c.title ?? "", url: c.feedUrl || c.siteUrl || "" }))
    .filter((c) => c.url);
}

function accessHeaders() {
  const host = new URL(TAYORI_URL).hostname;
  if (host === "127.0.0.1" || host === "localhost") return {};
  const read = (account) =>
    execFileSync("security", ["find-generic-password", "-s", "tayori-token", "-a", account, "-w"], { encoding: "utf8" }).trim();
  try {
    return { "CF-Access-Client-Id": read("client-id"), "CF-Access-Client-Secret": read("client-secret") };
  } catch {
    throw new Error("キーチェーンに tayori-token（client-id / client-secret）がありません（scripts/setup-access.sh）");
  }
}

async function main() {
  const subs = await fetchSubscriptions();
  console.log(`rururu の購読: ${subs.length} 件`);
  if (dryRun) {
    for (const s of subs) console.log(`  - ${s.title || "（無題）"}  ${s.url}`);
    console.log("（--dry-run なので便りには送っていません）");
    return;
  }
  const headers = { "Content-Type": "application/json", ...accessHeaders() };
  const tally = { created: 0, exists: 0, failed: 0 };
  for (const s of subs) {
    let label;
    try {
      const res = await fetch(`${TAYORI_URL}/api/feeds`, {
        method: "POST",
        headers,
        body: JSON.stringify({ url: s.url, category_id: null }),
        redirect: "manual",
      });
      const j = await res.json().catch(() => ({}));
      if (res.status === 201) (tally.created++, (label = "追加"));
      else if (res.status === 200) (tally.exists++, (label = "購読済み"));
      else (tally.failed++, (label = `失敗（${res.status} ${j.error ?? ""}）`));
    } catch (e) {
      tally.failed++;
      label = `失敗（${e instanceof Error ? e.name : "error"}）`;
    }
    console.log(`  ${label}: ${s.title || s.url}`);
  }
  console.log(`完了: 追加 ${tally.created}・購読済み ${tally.exists}・失敗 ${tally.failed}`);
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : "失敗しました");
  process.exit(1);
});
