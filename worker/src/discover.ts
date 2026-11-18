// サイトの HTML から <link rel="alternate" type="application/rss+xml" ...> を拾う（書いてある順）。
// Workers の HTMLRewriter はテスト（node）で動かないので、<link> だけを正規表現で読む。
import { absUrl, decodeEntities } from "./parse.ts";

const FEED_TYPES = new Set([
  "application/rss+xml",
  "application/atom+xml",
  "application/rdf+xml",
  "application/feed+json",
  "application/json",
  "text/xml",
  "application/xml",
]);

function attrs(tag: string): Record<string, string> {
  const out: Record<string, string> = {};
  const re = /([a-zA-Z_:][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(tag))) out[m[1].toLowerCase()] = decodeEntities(m[2] ?? m[3] ?? m[4] ?? "");
  return out;
}

/** HTML からフィードの URL 候補（重複なし・書いてある順・コメント用フィードは後ろへ） */
export function findFeedLinks(html: string, pageUrl: string): string[] {
  const head = html.slice(0, 512 * 1024).replace(/<!--[\s\S]*?-->/g, "");
  const baseTag = /<base\b[^>]*>/i.exec(head);
  const base = (baseTag && absUrl(attrs(baseTag[0]).href, pageUrl)) || pageUrl;
  const main: string[] = [];
  const comments: string[] = [];
  for (const m of head.matchAll(/<link\b[^>]*>/gi)) {
    const a = attrs(m[0]);
    const rel = (a.rel ?? "").toLowerCase().split(/\s+/);
    const type = (a.type ?? "").toLowerCase().split(";")[0].trim();
    if (!rel.includes("alternate") || !FEED_TYPES.has(type)) continue;
    const href = absUrl(a.href, base);
    if (!href || main.includes(href) || comments.includes(href)) continue;
    const isComments = /comment|コメント/i.test(a.title ?? "") || /\/comments\/feed/i.test(href);
    (isComments ? comments : main).push(href);
  }
  return [...main, ...comments];
}
