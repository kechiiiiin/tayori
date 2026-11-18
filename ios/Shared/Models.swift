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
    let categoryId: Int?
    let title: String
    let siteUrl: String?
    let feedUrl: String
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
