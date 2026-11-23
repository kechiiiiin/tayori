import Foundation

/// 回の説明（ショーノート・HTML）を読みやすい文字に: 段落は空行・<br> は改行・<li> は「・」・<a href> はリンク。
/// script／style／画像などは出さない。タグの無い説明は改行をそのまま改行に。地の文の URL もリンクにする。
/// 開くのは http(s) のリンクだけ（アプリ内 Safari）
enum ShowNotes {
    /// 1かたまりの文字（リンクなら url）
    struct Run: Equatable {
        var text: String
        var url: URL?
    }

    static func attributed(fromHTML html: String) -> AttributedString {
        var out = AttributedString()
        for r in runs(fromHTML: html) {
            var a = AttributedString(r.text)
            if let u = r.url { a.link = u }
            out += a
        }
        linkBareURLs(in: &out)
        return out
    }

    /// テスト用: 文字だけ
    static func plain(fromHTML html: String) -> String {
        runs(fromHTML: html).map(\.text).joined()
    }

    // MARK: - 中身

    private static let dropped = ["script", "style", "iframe", "noscript", "svg", "object", "template", "head", "title"]
    private static let blocks: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "aside", "main", "nav", "figure", "figcaption",
        "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "dl", "dt", "dd", "blockquote", "pre", "table", "tr", "hr", "address",
    ]

    static func runs(fromHTML raw: String) -> [Run] {
        var html = raw
        // コメントと、中身ごと出さない要素（閉じていなければ終わりまで）
        html = html.replacingOccurrences(of: #"(?s)<!--.*?(-->|$)"#, with: "", options: .regularExpression)
        for tag in dropped {
            html = html.replacingOccurrences(of: "(?is)<\(tag)\\b[^>]*>.*?(</\(tag)\\s*>|$)", with: "", options: .regularExpression)
            html = html.replacingOccurrences(of: "(?i)</?\(tag)\\b[^>]*>", with: "", options: .regularExpression)
        }
        // タグ（段落・改行）の無い説明は、改行をそのまま改行として扱う
        let hasStructure = html.range(of: #"(?i)<(br|p|div|li|h[1-6])\b"#, options: .regularExpression) != nil
        if !hasStructure {
            html = html.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
        }

        var out: [Run] = []
        var pending = 0 // 次の文字の前に入れる改行の数（2 = 段落）
        var linkStack: [URL?] = []
        var olCounters: [Int?] = [] // ul は nil、ol は番号

        func emit(_ text: String) {
            guard !text.isEmpty else { return }
            var t = text
            let atLineStart = out.isEmpty || pending > 0 || (out.last?.text.hasSuffix("\n") ?? true)
            if atLineStart { t = String(t.drop(while: { $0 == " " })) }
            guard !t.isEmpty else { return }
            if pending > 0, !out.isEmpty {
                let tail = out.last!.text.reversed().prefix(while: { $0 == "\n" }).count
                if pending > tail { out.append(Run(text: String(repeating: "\n", count: pending - tail), url: nil)) }
            }
            pending = 0
            let url = linkStack.last ?? nil
            if let last = out.last, last.url == url, !last.text.hasSuffix("\n") {
                out[out.count - 1].text += t
            } else {
                out.append(Run(text: t, url: url))
            }
        }

        func breakLine(_ n: Int) {
            guard !out.isEmpty else { return }
            pending = max(pending, n)
        }

        let pattern = try! NSRegularExpression(pattern: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>"#)
        let ns = html as NSString
        var cursor = 0
        for m in pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                emit(clean(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
            }
            cursor = m.range.location + m.range.length
            let closing = ns.substring(with: m.range(at: 1)) == "/"
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            let attrs = ns.substring(with: m.range(at: 3))
            switch name {
            case "br":
                // <br> は改行（続けて書かれた <br><br> は空行まで）
                if !out.isEmpty {
                    if pending > 0 { pending = min(pending + 1, 2) } else { pending = 1 }
                }
            case "a":
                if closing { if !linkStack.isEmpty { linkStack.removeLast() } } else { linkStack.append(href(attrs)) }
            case "ul", "ol":
                if closing {
                    if !olCounters.isEmpty { olCounters.removeLast() }
                } else {
                    olCounters.append(name == "ol" ? 0 : nil)
                }
                breakLine(2)
            case "li":
                if closing { breakLine(1); continue }
                breakLine(1)
                var bullet = "・"
                if let last = olCounters.last, let n = last {
                    olCounters[olCounters.count - 1] = n + 1
                    bullet = "\(n + 1). "
                }
                // 印は前のリンクに混ぜない
                let saved = linkStack
                linkStack = []
                emit(bullet)
                linkStack = saved
            case "td", "th":
                if !closing { emit(" ") }
            case "img":
                break
            default:
                if blocks.contains(name) { breakLine(2) }
            }
        }
        if cursor < ns.length { emit(clean(ns.substring(from: cursor))) }
        // 末尾の空白・改行を落とす
        while let last = out.last {
            let t = String(last.text.reversed().drop(while: { $0 == "\n" || $0 == " " }).reversed())
            if t.isEmpty { out.removeLast() } else { out[out.count - 1].text = t; break }
        }
        return out
    }

    /// 地の文: 空白を詰め、実体参照を戻す（書きかけのタグの「<」は残さない）
    private static func clean(_ s: String) -> String {
        let t = s.replacingOccurrences(of: #"<[^>]*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return decodeEntities(t)
    }

    private static func href(_ attrs: String) -> URL? {
        guard let m = attrs.range(of: #"(?i)href\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, options: .regularExpression) else { return nil }
        var v = String(attrs[m])
        v = String(v[v.index(after: v.firstIndex(of: "=")!)...]).trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") || v.hasPrefix("'") { v = String(v.dropFirst().dropLast()) }
        v = decodeEntities(v).trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: v), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return u
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "yen": "¥", "middot": "·", "times": "×",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let re = try! NSRegularExpression(pattern: #"&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z]+);"#)
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let e = ns.substring(with: m.range(at: 1))
            var rep: String?
            if e.hasPrefix("#x") || e.hasPrefix("#X") {
                rep = UInt32(e.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if e.hasPrefix("#") {
                rep = UInt32(e.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                rep = named[e.lowercased()]
            }
            out += rep ?? ns.substring(with: m.range)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// 地の文の http(s) の URL をリンクに（もうリンクのところは触らない）
    private static func linkBareURLs(in a: inout AttributedString) {
        let text = String(a.characters)
        guard text.contains("http"), let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        for m in det.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = m.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let r = Range(m.range, in: a) else { continue }
            if a[r].runs.contains(where: { $0.link != nil }) { continue }
            a[r].link = url
        }
    }
}
