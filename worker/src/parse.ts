// フィードを読む: RSS 2.0・RSS 1.0（RDF）・Atom・JSON Feed。フィードでなければ null。
// Workers には DOMParser が無いので、XML は fast-xml-parser（純 JS）で読む。
import { XMLParser } from "fast-xml-parser";

export interface ParsedItem {
  /** 重複を除く鍵（guid／id → url → 題名の順） */
  guid: string;
  url: string | null;
  title: string;
  /** ISO 8601（UTC）。読めなければ null */
  published_at: string | null;
  /** 音声などの添付（RSS の <enclosure>・Atom の rel=enclosure・JSON Feed の attachments）。無ければ null */
  enclosure_url?: string | null;
  enclosure_type?: string | null;
  /** 長さ（秒・itunes:duration か JSON Feed の duration_in_seconds）。無ければ null */
  duration_sec?: number | null;
}

export interface ParsedFeed {
  kind: "rss" | "rdf" | "atom" | "json";
  title: string;
  site_url: string | null;
  /** ポッドキャストの番組アートワーク（RSS のチャンネルの itunes:image@href）。無ければ null */
  image_url: string | null;
  items: ParsedItem[];
}

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  parseTagValue: false,
  parseAttributeValue: false,
  trimValues: true,
  processEntities: true,
  htmlEntities: true,
  isArray: (name) => ["item", "entry", "link", "category", "enclosure"].includes(name),
});

type Node = unknown;

/** 要素の文字（"#text"・CDATA・数値も） */
function text(v: Node): string {
  if (v == null) return "";
  if (typeof v === "string") return v;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (Array.isArray(v)) return v.length ? text(v[0]) : "";
  if (typeof v === "object") {
    const o = v as Record<string, unknown>;
    if ("#text" in o) return text(o["#text"]);
    if ("__cdata" in o) return text(o["__cdata"]);
  }
  return "";
}

const NAMED: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

/** HTML の実体参照を戻す（題名に二重にエスケープされた HTML が入ってくることがある） */
export function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, e: string) => {
    if (e[0] === "#") {
      const n = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(n) && n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : m;
    }
    return NAMED[e.toLowerCase()] ?? m;
  });
}

/** 題名を1行の素の文字に（タグを落とし、実体参照を戻し、空白を詰める） */
export function cleanTitle(s: string): string {
  return decodeEntities(s.replace(/<[^>]*>/g, ""))
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 500);
}

/** http(s) の絶対 URL に。相対なら base から解く。だめなら null */
export function absUrl(u: string | null | undefined, base: string): string | null {
  const s = (u ?? "").trim();
  if (!s) return null;
  try {
    const url = new URL(s, base);
    return url.protocol === "http:" || url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

/** 日付を ISO（UTC）に。読めなければ null */
export function toIso(s: string): string | null {
  const v = s.trim();
  if (!v) return null;
  const t = Date.parse(v);
  if (Number.isFinite(t)) return new Date(t).toISOString();
  // "2026-11-18 12:00:00" のような区切り（タイムゾーン無しは JST とみなす）
  const m = /^(\d{4})[-/](\d{1,2})[-/](\d{1,2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(v);
  if (m) {
    const [, y, mo, d, h, mi, se] = m;
    const t2 = Date.UTC(+y, +mo - 1, +d, +h - 9, +mi, +(se ?? 0));
    return Number.isFinite(t2) ? new Date(t2).toISOString() : null;
  }
  return null;
}

interface Enclosure {
  enclosure_url: string | null;
  enclosure_type: string | null;
  duration_sec: number | null;
}
const NO_ENCLOSURE: Enclosure = { enclosure_url: null, enclosure_type: null, duration_sec: null };

function item(guid: string, url: string | null, title: string, published: string, enc: Enclosure = NO_ENCLOSURE): ParsedItem | null {
  const t = cleanTitle(title);
  // 記事の URL が無いエピソードは音声の URL を鍵に（guid も link も無い配信がある）
  const key = guid.trim() || url || enc.enclosure_url || t;
  if (!key) return null;
  const base = { guid: key.slice(0, 1000), url, title: t || url || "（無題）", published_at: toIso(published) };
  // 添付の無い記事は今までと同じ形のまま
  return enc.enclosure_url ? { ...base, ...enc } : base;
}

/** itunes:duration（"3725"・"62:05"・"1:02:05"）を秒に。読めなければ null */
export function parseDuration(v: string): number | null {
  const s = v.trim();
  if (!s) return null;
  if (/^\d+(\.\d+)?$/.test(s)) {
    const n = Math.round(Number(s));
    return n > 0 && n < 86400 * 2 ? n : null;
  }
  const m = /^(?:(\d{1,3}):)?(\d{1,3}):(\d{1,2})(?:\.\d+)?$/.exec(s);
  if (!m) return null;
  const n = Number(m[1] ?? 0) * 3600 + Number(m[2]) * 60 + Number(m[3]);
  return n > 0 ? n : null;
}

/** 音声らしい添付を優先して1つ選ぶ（audio/* → video/* → 種類不明 → その他） */
function pickEnclosure(cands: { url: string | null; type: string | null }[]): { url: string; type: string | null } | null {
  const ok = cands.filter((c): c is { url: string; type: string | null } => !!c.url);
  const rank = (t: string | null) => (t?.startsWith("audio/") ? 0 : t?.startsWith("video/") ? 1 : !t ? 2 : 3);
  return ok.sort((a, b) => rank(a.type) - rank(b.type))[0] ?? null;
}

function attr(o: unknown, name: string): string | null {
  if (!o || typeof o !== "object") return null;
  const v = (o as Record<string, unknown>)["@_" + name];
  return typeof v === "string" && v.trim() ? v.trim() : null;
}

/** RSS の <enclosure url type length> と <itunes:duration> */
function rssEnclosure(i: Record<string, unknown>, base: string): Enclosure {
  const raw = i["enclosure"];
  const list = Array.isArray(raw) ? raw : raw == null ? [] : [raw];
  const enc = pickEnclosure(list.map((e) => ({ url: absUrl(attr(e, "url"), base), type: attr(e, "type")?.toLowerCase() ?? null })));
  if (!enc) return NO_ENCLOSURE;
  return { enclosure_url: enc.url, enclosure_type: enc.type, duration_sec: parseDuration(text(i["itunes:duration"])) };
}

/** Atom の <link rel="enclosure" href type> */
function atomEnclosure(links: Node, base: string): Enclosure {
  const arr = Array.isArray(links) ? links : links == null ? [] : [links];
  const enc = pickEnclosure(
    arr.filter((l) => attr(l, "rel") === "enclosure").map((l) => ({ url: absUrl(attr(l, "href"), base), type: attr(l, "type")?.toLowerCase() ?? null })),
  );
  return enc ? { enclosure_url: enc.url, enclosure_type: enc.type, duration_sec: null } : NO_ENCLOSURE;
}

/** Atom の link 群から rel=alternate（無ければ rel 無し）の href */
function atomLink(links: Node, base: string): string | null {
  const arr = Array.isArray(links) ? links : links == null ? [] : [links];
  let fallback: string | null = null;
  for (const l of arr) {
    if (typeof l === "string") {
      fallback ??= absUrl(l, base);
      continue;
    }
    const o = l as Record<string, unknown>;
    const rel = typeof o["@_rel"] === "string" ? (o["@_rel"] as string) : "";
    const href = absUrl(typeof o["@_href"] === "string" ? (o["@_href"] as string) : text(o), base);
    if (!href) continue;
    if (rel === "alternate") return href;
    if (!rel) fallback ??= href;
  }
  return fallback;
}

/** チャンネルの <itunes:image href="..."/>（ポッドキャストの番組アートワーク）。ブログの <image> は見ない */
function itunesImage(channel: Record<string, unknown>, base: string): string | null {
  const v = channel["itunes:image"];
  for (const o of Array.isArray(v) ? v : [v]) {
    if (o && typeof o === "object") {
      const href = (o as Record<string, unknown>)["@_href"];
      const u = absUrl(typeof href === "string" ? href : null, base);
      if (u) return u;
    }
  }
  return null;
}

function parseRss(channel: Record<string, unknown>, items: Node[], base: string, kind: "rss" | "rdf"): ParsedFeed {
  const out: ParsedItem[] = [];
  for (const raw of items) {
    if (!raw || typeof raw !== "object") continue;
    const i = raw as Record<string, unknown>;
    const link = atomLink(i["link"], base) ?? absUrl(text(i["link"]), base);
    const guid = text(i["guid"]) || (typeof i["@_rdf:about"] === "string" ? (i["@_rdf:about"] as string) : "");
    const it = item(guid, link, text(i["title"]), text(i["pubDate"]) || text(i["dc:date"]) || text(i["published"]), rssEnclosure(i, base));
    if (it) out.push(it);
  }
  return {
    kind,
    title: cleanTitle(text(channel["title"])),
    site_url: atomLink(channel["link"], base),
    image_url: itunesImage(channel, base),
    items: out,
  };
}

function parseAtom(feed: Record<string, unknown>, base: string): ParsedFeed {
  const entries = (feed["entry"] as Node[] | undefined) ?? [];
  const out: ParsedItem[] = [];
  for (const raw of entries) {
    if (!raw || typeof raw !== "object") continue;
    const e = raw as Record<string, unknown>;
    const link = atomLink(e["link"], base);
    const it = item(text(e["id"]), link, text(e["title"]), text(e["published"]) || text(e["updated"]), atomEnclosure(e["link"], base));
    if (it) out.push(it);
  }
  return { kind: "atom", title: cleanTitle(text(feed["title"])), site_url: atomLink(feed["link"], base), image_url: null, items: out };
}

function parseJsonFeed(body: string, base: string): ParsedFeed | null {
  let j: unknown;
  try {
    j = JSON.parse(body);
  } catch {
    return null;
  }
  if (!j || typeof j !== "object" || Array.isArray(j)) return null;
  const f = j as Record<string, unknown>;
  const version = typeof f.version === "string" ? f.version : "";
  if (!version.startsWith("https://jsonfeed.org/version/") || !Array.isArray(f.items)) return null;
  const out: ParsedItem[] = [];
  for (const raw of f.items) {
    if (!raw || typeof raw !== "object") continue;
    const i = raw as Record<string, unknown>;
    const url = absUrl(typeof i.url === "string" ? i.url : typeof i.external_url === "string" ? i.external_url : null, base);
    const id = typeof i.id === "string" || typeof i.id === "number" ? String(i.id) : "";
    const title = typeof i.title === "string" ? i.title : typeof i.content_text === "string" ? i.content_text.slice(0, 80) : "";
    const pub = typeof i.date_published === "string" ? i.date_published : typeof i.date_modified === "string" ? i.date_modified : "";
    const atts = Array.isArray(i.attachments) ? (i.attachments as Record<string, unknown>[]) : [];
    const enc = pickEnclosure(
      atts.map((a) => ({
        url: absUrl(typeof a?.url === "string" ? a.url : null, base),
        type: typeof a?.mime_type === "string" ? a.mime_type.toLowerCase() : null,
      })),
    );
    const att = enc ? atts.find((a) => absUrl(typeof a?.url === "string" ? a.url : null, base) === enc.url) : undefined;
    const dur = typeof att?.duration_in_seconds === "number" && att.duration_in_seconds > 0 ? Math.round(att.duration_in_seconds) : null;
    const it = item(id, url, title, pub, enc ? { enclosure_url: enc.url, enclosure_type: enc.type, duration_sec: dur } : NO_ENCLOSURE);
    if (it) out.push(it);
  }
  return {
    kind: "json",
    title: cleanTitle(typeof f.title === "string" ? f.title : ""),
    site_url: absUrl(typeof f.home_page_url === "string" ? f.home_page_url : null, base),
    image_url: null,
    items: out,
  };
}

/** 本文をフィードとして読む。RSS／Atom／JSON Feed のどれでもなければ null */
export function parseFeed(body: string, base: string): ParsedFeed | null {
  const s = body.replace(/^﻿/, "").trimStart();
  if (s.startsWith("{")) return parseJsonFeed(s, base);
  if (!s.startsWith("<")) return null;
  let doc: Record<string, unknown>;
  try {
    doc = parser.parse(s) as Record<string, unknown>;
  } catch {
    return null;
  }
  const rss = doc["rss"] as Record<string, unknown> | undefined;
  if (rss && typeof rss === "object") {
    const ch = (rss["channel"] ?? {}) as Record<string, unknown>;
    return parseRss(ch, (ch["item"] as Node[] | undefined) ?? [], base, "rss");
  }
  const rdf = doc["rdf:RDF"] as Record<string, unknown> | undefined;
  if (rdf && typeof rdf === "object") {
    const ch = (rdf["channel"] ?? {}) as Record<string, unknown>;
    return parseRss(ch, (rdf["item"] as Node[] | undefined) ?? [], base, "rdf");
  }
  const feed = doc["feed"] as Record<string, unknown> | undefined;
  if (feed && typeof feed === "object") return parseAtom(feed, base);
  return null;
}

/** 新しい順に n 件（全件に日付があれば日付で、無いものがあればフィードの並びのまま） */
export function newest(items: ParsedItem[], n: number): ParsedItem[] {
  if (items.every((i) => i.published_at)) {
    return [...items].sort((a, b) => (a.published_at! < b.published_at! ? 1 : a.published_at! > b.published_at! ? -1 : 0)).slice(0, n);
  }
  return items.slice(0, n);
}
