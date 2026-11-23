import Foundation
import Observation

/// アプリ全体の状態: 一覧の絞り込みと記事、カテゴリ（未読数つき）、サイト、さっき開いた記事
@MainActor
@Observable
final class AppModel {
    // 絞り込み
    var state: ItemState = .unread
    var category: CategoryFilter = .all
    /// サイト画面・iPad のサイドバーで選んだサイト（nil = 絞らない）
    var feedFilter: Feed?

    // 中身
    var items: [Item] = []
    var next: String?
    var categories: CategoryList = .empty
    var feeds: [Feed] = []

    // 記事を開く → 戻る → バー
    /// アプリ内 Safari で開いている記事
    var presented: Item?
    /// さっき開いた記事（戻ってきたら下に「既読にする」「コメント」のバーが出る）
    var lastOpened: Item?
    /// コメントのシートを出している記事
    var commentTarget: Item?
    /// コメントのシートの最初の文（DEBUG のスクリーンショット用。ふだんは記事のコメント）
    var commentDraft: String?

    var isLoading = false
    var errorMessage: String?
    var isConfigured = TayoriAPI.shared.isConfigured

    private let api = TayoriAPI.shared
    private var loadToken = 0
    /// 起動後の最初の読み込みで、名前が「メイン」のカテゴリへ絞り込む（1回だけ。あとは選んだものを尊重する）
    static let launchCategoryName = "メイン"
    private var appliedLaunchCategory = false

    // MARK: - 読み込み

    func refreshConfigured() { isConfigured = api.isConfigured }

    /// 一覧とカテゴリ・サイトを読み直す
    func reload() async {
        refreshConfigured()
        guard isConfigured else { return }
        loadToken += 1
        let token = loadToken
        isLoading = true
        defer { if token == loadToken { isLoading = false } }
        do {
            let p: ItemPage
            let c: CategoryList
            let f: [Feed]
            if appliedLaunchCategory {
                async let page = api.items(state: state, category: category, feed: feedFilter?.id, before: nil)
                async let cats = api.categories()
                async let fs = api.feeds()
                (p, c, f) = try await (page, cats, fs)
            } else {
                // 初回: 先にカテゴリを取り、「メイン」があればそれで絞ってから一覧を取る
                async let fs = api.feeds()
                let cats = try await api.categories()
                appliedLaunchCategory = true
                if category == .all, feedFilter == nil,
                   let main = cats.categories.first(where: { $0.name == Self.launchCategoryName }) {
                    category = .category(main.id)
                }
                p = try await api.items(state: state, category: category, feed: feedFilter?.id, before: nil)
                c = cats
                f = try await fs
            }
            guard token == loadToken else { return }
            items = p.items
            next = p.next
            categories = c
            feeds = f
            if let ff = feedFilter { feedFilter = f.first { $0.id == ff.id } }
            errorMessage = nil
        } catch {
            if token == loadToken { errorMessage = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard let cursor = next, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let p = try await api.items(state: state, category: category, feed: feedFilter?.id, before: cursor)
            let known = Set(items.map(\.id))
            items += p.items.filter { !known.contains($0.id) }
            next = p.next
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshMeta() async {
        do {
            async let c = api.categories()
            async let f = api.feeds()
            (categories, feeds) = try await (c, f)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(state s: ItemState) {
        state = s
        Task { await reload() }
    }

    func select(category c: CategoryFilter) {
        category = c
        feedFilter = nil
        Task { await reload() }
    }

    /// カテゴリのタブの並び（すべて → 各カテゴリ → 未分類）。CategoryBar と同じ順
    var categoryOrder: [CategoryFilter] {
        [.all] + categories.categories.map { .category($0.id) } + [.none]
    }

    /// 隣のカテゴリへ（delta = +1 で右隣、-1 で左隣）。端では止まる
    func shiftCategory(by delta: Int) {
        let order = categoryOrder
        guard let i = order.firstIndex(of: category) else { return }
        let j = i + delta
        guard order.indices.contains(j) else { return }
        select(category: order[j])
    }

    func select(feed f: Feed?) {
        feedFilter = f
        if f != nil { category = .all }
        Task { await reload() }
    }

    // MARK: - 数

    /// いまのタブで出す数（未読タブ・すべては未読数、コメントありはコメント数）
    func count(_ c: Counts) -> Int { state == .commented ? c.commented : c.unread }

    var title: String {
        switch state {
        case .unread:
            let n: Int
            switch category {
            case .all: n = feedFilter?.unread ?? categories.total.unread
            case .none: n = categories.uncategorized.unread
            case .category(let id): n = categories.categories.first { $0.id == id }?.unread ?? 0
            }
            return "未読 \(n)"
        case .commented: return "コメントあり"
        case .all: return "すべて"
        }
    }

    // MARK: - 記事を開く・既読・コメント

    func open(_ item: Item) {
        guard item.link != nil else {
            lastOpened = item
            return
        }
        presented = item
    }

    /// アプリ内 Safari を閉じた（＝戻ってきた）
    func returned(from item: Item) {
        lastOpened = items.first { $0.id == item.id } ?? item
    }

    func setRead(_ item: Item, _ read: Bool) async {
        do {
            let updated = try await api.setRead(item.id, read)
            apply(updated)
            if read, lastOpened?.id == item.id { lastOpened = nil }
            await refreshMeta()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// コメントを保存（andRead なら既読にも）。うまくいったら true
    func saveComment(_ item: Item, text: String, andRead: Bool) async -> Bool {
        do {
            var updated = try await api.setComment(item.id, text)
            if andRead { updated = try await api.setRead(item.id, true) }
            apply(updated)
            if andRead, lastOpened?.id == item.id { lastOpened = nil }
            else if lastOpened?.id == item.id { lastOpened = updated }
            await refreshMeta()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// 書き換わった記事を一覧へ。いまのタブに合わなくなったら外す
    private func apply(_ updated: Item) {
        guard let i = items.firstIndex(where: { $0.id == updated.id }) else { return }
        let keep: Bool
        switch state {
        case .unread: keep = !updated.isRead
        case .commented: keep = updated.comment != nil
        case .all: keep = true
        }
        if keep { items[i] = updated } else { items.remove(at: i) }
    }

    // MARK: - サイト

    enum AddOutcome: Equatable {
        case added(title: String, category: String)
        case exists(title: String)
        case failed(String)
    }

    func addFeed(url: String, categoryId: Int?) async -> AddOutcome {
        do {
            let r = try await api.addFeed(url: url, categoryId: categoryId)
            await reload()
            return r.created ? .added(title: r.feed.title, category: categories.name(of: r.feed.categoryId)) : .exists(title: r.feed.title)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func moveFeed(_ feed: Feed, to categoryId: Int?) async {
        await run { _ = try await self.api.setFeedCategory(feed.id, categoryId) }
    }

    func deleteFeed(_ feed: Feed) async {
        if feedFilter?.id == feed.id { feedFilter = nil }
        await run { try await self.api.deleteFeed(feed.id) }
    }

    func refreshFeed(_ feed: Feed) async {
        await run { _ = try await self.api.refreshFeed(feed.id) }
    }

    // MARK: - カテゴリ

    @discardableResult
    func createCategory(_ name: String) async -> Category? {
        do {
            let c = try await api.createCategory(name)
            await refreshMeta()
            return c
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renameCategory(_ c: Category, to name: String) async {
        await run { _ = try await self.api.updateCategory(c.id, name: name) }
    }

    func moveCategory(_ c: Category, by delta: Int) async {
        guard let i = categories.categories.firstIndex(of: c) else { return }
        let to = max(0, min(categories.categories.count - 1, i + delta))
        guard to != i else { return }
        await run { _ = try await self.api.updateCategory(c.id, sort: to) }
    }

    func deleteCategory(_ c: Category) async {
        if category == .category(c.id) { category = .all }
        await run { _ = try await self.api.deleteCategory(c.id) }
    }

    private func run(_ op: @escaping () async throws -> Void) async {
        do {
            try await op()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    func feeds(in categoryId: Int?) -> [Feed] {
        feeds.filter { $0.categoryId == categoryId }
    }
}
