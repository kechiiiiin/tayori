import Foundation

/// 一覧のタブ
enum ItemState: String, CaseIterable, Identifiable, Sendable {
    case unread, commented, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .unread: return "未読"
        case .commented: return "コメントあり"
        case .all: return "すべて"
        }
    }
}

/// カテゴリの絞り込み（すべて／あるカテゴリ／未分類）
enum CategoryFilter: Hashable, Sendable {
    case all
    case category(Int)
    case none

    var query: String? {
        switch self {
        case .all: return nil
        case .category(let id): return String(id)
        case .none: return "none"
        }
    }
}

struct Item: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let feedId: Int
    let feedTitle: String
    let categoryId: Int?
    let title: String
    let url: String?
    let publishedAt: String?
    let sortAt: String
    var readAt: String?
    var comment: String?
    var commentUpdatedAt: String?

    var isRead: Bool { readAt != nil }
    var link: URL? { url.flatMap(URL.init(string:)) }
}

struct ItemPage: Codable, Sendable {
    let items: [Item]
    let next: String?
}

struct ItemEnvelope: Codable, Sendable {
    let item: Item
}

struct Counts: Codable, Hashable, Sendable {
    let unread: Int
    let commented: Int
}

struct Category: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let sort: Int
    let unread: Int
    let commented: Int

    var counts: Counts { Counts(unread: unread, commented: commented) }
}

struct CategoryList: Codable, Hashable, Sendable {
    let categories: [Category]
    let uncategorized: Counts
    let total: Counts

    static let empty = CategoryList(categories: [], uncategorized: Counts(unread: 0, commented: 0), total: Counts(unread: 0, commented: 0))

    func name(of id: Int?) -> String {
        guard let id else { return "未分類" }
        return categories.first { $0.id == id }?.name ?? "未分類"
    }
}

struct CreatedCategory: Codable, Sendable {
    let category: Category
}

struct Feed: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    /// article／podcast（古い Worker では nil）
    let kind: String?
    let categoryId: Int?
    let title: String
    let siteUrl: String?
    let feedUrl: String
    /// ポッドキャストの番組アートワーク（RSS の itunes:image）。無いフィード・古い Worker では nil
    let imageUrl: String?
    let lastFetchedAt: String?
    let lastError: String?
    let unread: Int
    let createdAt: String

    /// 一覧に出す短い URL（スキームと末尾の / を落とす）
    var displayURL: String {
        let s = siteUrl ?? feedUrl
        return s.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)
    }

    /// 頭文字（アイコン代わり）
    var initial: String {
        String(title.trimmingCharacters(in: .whitespaces).first ?? "・").uppercased()
    }

    /// 行とサイト一覧に出すアイコン: 番組アートワークがあればそれ、無ければファビコン
    var iconURL: URL? {
        if let s = imageUrl, let u = URL(string: s), u.scheme == "https" || u.scheme == "http" { return u }
        return faviconURL
    }

    /// ファビコンの URL（Google の s2/favicons を経由。ホストが取れなければ nil）
    var faviconURL: URL? {
        guard let host = URL(string: siteUrl ?? feedUrl)?.host else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
    }
}

struct FeedList: Codable, Sendable {
    let feeds: [Feed]
}

struct FeedEnvelope: Codable, Sendable {
    let feed: Feed
}

struct AddFeedResult: Codable, Sendable {
    let feed: Feed
    let created: Bool
}

// MARK: - 時刻の表示

enum When {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac = ISO8601DateFormatter()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoNoFrac.date(from: s)
    }

    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// 「2時間前」「昨日」「3日前」「11/16」
    static func relative(_ s: String?, now: Date = Date()) -> String {
        guard let d = date(s) else { return "" }
        let sec = now.timeIntervalSince(d)
        if sec < 60 { return "いま" }
        if sec < 3600 { return "\(Int(sec / 60))分前" }
        let cal = calendar
        if cal.isDateInToday(d) || sec < 6 * 3600 { return "\(Int(sec / 3600))時間前" }
        if cal.isDateInYesterday(d) { return "昨日" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
        if days < 7 { return "\(days)日前" }
        return short(d)
    }

    /// 既読の時刻: 「今朝」「今日」「昨日」「11/16」
    static func readLabel(_ s: String?, now: Date = Date()) -> String {
        guard let d = date(s) else { return "" }
        let cal = calendar
        if cal.isDateInToday(d) { return cal.component(.hour, from: d) < 11 ? "今朝" : "今日" }
        if cal.isDateInYesterday(d) { return "昨日" }
        return short(d)
    }

    private static func short(_ d: Date) -> String {
        let c = calendar.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }
}

// MARK: - ポッドキャスト（段階3）

/// 番組（GET /api/podcasts）
struct Podcast: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let siteUrl: String?
    let feedUrl: String
    let imageUrl: String?
    let lastFetchedAt: String?
    let lastError: String?
    let createdAt: String
    /// 再生できる回の数
    let episodes: Int
    /// いちばん大きいエピソードの id（「まだ見ていない回」の目印）
    let latestEpisodeId: Int?
    let latestAt: String?

    var artworkURL: URL? { imageUrl.flatMap(URL.init(string:)) }
}

struct PodcastList: Codable, Sendable {
    let podcasts: [Podcast]
}

struct PodcastEnvelope: Codable, Sendable {
    let podcast: Podcast
}

struct AddPodcastResult: Codable, Sendable {
    let podcast: Podcast
    let created: Bool
    let converted: Bool?
}

/// エピソード（GET /api/podcasts/:id/episodes・/api/episodes）
struct Episode: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let feedId: Int
    let feedTitle: String
    let feedImageUrl: String?
    let title: String
    let url: String?
    let publishedAt: String?
    let sortAt: String
    let enclosureUrl: String
    let enclosureType: String?
    let durationSec: Int?

    var audioURL: URL? { URL(string: enclosureUrl) }
    var artworkURL: URL? { feedImageUrl.flatMap(URL.init(string:)) }
    /// ダウンロードしたファイルの拡張子（URL から。分からなければ mp3）
    var fileExtension: String {
        let ext = audioURL?.pathExtension.lowercased() ?? ""
        if ["mp3", "m4a", "mp4", "aac", "wav", "ogg", "opus", "m4b", "mov"].contains(ext) { return ext }
        switch enclosureType ?? "" {
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/aac": return "aac"
        default: return "mp3"
        }
    }
}

struct EpisodePage: Codable, Sendable {
    let episodes: [Episode]
    let next: String?
}

/// iTunes Search API（番組を名前で探す）の1件
struct PodcastSearchResult: Codable, Identifiable, Hashable, Sendable {
    let collectionId: Int
    let collectionName: String
    let artistName: String?
    let feedUrl: String?
    let artworkUrl600: String?
    let artworkUrl100: String?

    var id: Int { collectionId }
    var artworkURL: URL? { (artworkUrl600 ?? artworkUrl100).flatMap(URL.init(string:)) }
}

struct PodcastSearchResponse: Codable, Sendable {
    let results: [PodcastSearchResult]
}

/// 秒 → 「1:02:05」「42:30」
enum Duration {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// 「1時間2分」「42分」（一覧の長さ）
    static func label(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        let h = seconds / 3600, m = (seconds % 3600 + 59) / 60
        if h > 0 { return m > 0 ? "\(h)時間\(m)分" : "\(h)時間" }
        return "\(max(m, 1))分"
    }
}
