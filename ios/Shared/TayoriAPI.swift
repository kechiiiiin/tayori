import Foundation

enum APIError: LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    case http(Int, String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "サービストークンが入っていません（設定）"
        case .unauthorized: return "Cloudflare Access を通れませんでした（サービストークンを確かめてください）"
        case .transport(let m): return "通信できませんでした（\(m)）"
        case .http(let code, let e):
            switch e {
            case "feed_not_found": return "RSS が見つかりませんでした"
            case "fetch_failed": return "サイトを開けませんでした"
            case "bad_url": return "URL を確かめてください"
            case "bad_name": return "カテゴリの名前を確かめてください（40文字まで）"
            case "bad_comment": return "コメントが長すぎます"
            case "bad_category": return "カテゴリが見つかりません"
            case "not_found": return "見つかりませんでした（もう消えたかもしれません）"
            case "not_podcast": return "番組として足せませんでした"
            default: return "エラー（\(code) \(e)）"
            }
        }
    }
}

/// つなぎ先
enum ServerConfig {
    /// 本番。Info.plist の TayoriServerURL（project.yml の TAYORI_SERVER_URL から入る）
    static var productionURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "TayoriServerURL") as? String,
              let url = URL(string: s), url.host?.isEmpty == false else { return nil }
        return url
    }

    #if DEBUG
    private static let debugKey = "debugBaseURL"
    /// **DEBUG ビルドだけ**: シミュレータでローカルの Worker を見る。
    /// 起動引数 `-tayoriBaseURL http://127.0.0.1:8792` を App Group に写し、共有拡張も同じ先を見る
    static func applyLaunchOverride() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tayoriBaseURL"), args.index(after: i) < args.endIndex {
            AppGroup.defaults.set(args[args.index(after: i)], forKey: debugKey)
        }
    }
    static var debugURL: URL? {
        guard let s = AppGroup.defaults.string(forKey: debugKey), let url = URL(string: s),
              let scheme = url.scheme, scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
    #endif

    static var baseURL: URL? {
        #if DEBUG
        if let u = debugURL { return u }
        #endif
        return productionURL
    }

    /// ローカルの Worker（認証を迂回する dev）に向いているか。DEBUG のときだけ true になりうる
    static var isLocalDev: Bool {
        #if DEBUG
        guard let host = debugURL?.host else { return false }
        return host == "127.0.0.1" || host == "localhost"
        #else
        return false
        #endif
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Access のログイン画面への 302 を追わない
    }
}

/// 音沙汰の Worker を叩く（アプリと共有拡張で共通）
final class TayoriAPI: @unchecked Sendable {
    static let shared = TayoriAPI()

    private let session: URLSession
    private let noRedirect = NoRedirect()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30 // フィードを探す POST は相手のサイト次第で遅い
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        session = URLSession(configuration: config)
    }

    var isConfigured: Bool { ServerConfig.isLocalDev || (AccessTokenStore.isComplete && ServerConfig.baseURL != nil) }

    // MARK: - 記事

    func items(state: ItemState, category: CategoryFilter, feed: Int?, before: String?) async throws -> ItemPage {
        var q = [URLQueryItem(name: "state", value: state.rawValue)]
        if let c = category.query { q.append(URLQueryItem(name: "category", value: c)) }
        if let feed { q.append(URLQueryItem(name: "feed", value: String(feed))) }
        if let before { q.append(URLQueryItem(name: "before", value: before)) }
        return try await call("GET", "/api/items", query: q)
    }

    func item(_ id: Int) async throws -> Item {
        let r: ItemEnvelope = try await call("GET", "/api/items/\(id)")
        return r.item
    }

    func setRead(_ id: Int, _ read: Bool) async throws -> Item {
        let r: ItemEnvelope = try await call(read ? "POST" : "DELETE", "/api/items/\(id)/read")
        return r.item
    }

    func setComment(_ id: Int, _ comment: String) async throws -> Item {
        let r: ItemEnvelope = try await call("PUT", "/api/items/\(id)/comment", body: ["comment": comment])
        return r.item
    }

    // MARK: - カテゴリ

    func categories() async throws -> CategoryList { try await call("GET", "/api/categories") }

    func createCategory(_ name: String) async throws -> Category {
        let r: CreatedCategory = try await call("POST", "/api/categories", body: ["name": name])
        return r.category
    }

    func updateCategory(_ id: Int, name: String? = nil, sort: Int? = nil) async throws -> CategoryList {
        var b: [String: Any] = [:]
        if let name { b["name"] = name }
        if let sort { b["sort"] = sort }
        return try await call("PATCH", "/api/categories/\(id)", body: b)
    }

    func deleteCategory(_ id: Int) async throws -> CategoryList { try await call("DELETE", "/api/categories/\(id)") }

    // MARK: - フィード

    func feeds() async throws -> [Feed] {
        let r: FeedList = try await call("GET", "/api/feeds")
        return r.feeds
    }

    func addFeed(url: String, categoryId: Int?) async throws -> AddFeedResult {
        try await call("POST", "/api/feeds", body: ["url": url, "category_id": categoryId.map { $0 as Any } ?? NSNull()])
    }

    func setFeedCategory(_ id: Int, _ categoryId: Int?) async throws -> Feed {
        let r: FeedEnvelope = try await call("PATCH", "/api/feeds/\(id)", body: ["category_id": categoryId.map { $0 as Any } ?? NSNull()])
        return r.feed
    }

    func deleteFeed(_ id: Int) async throws {
        _ = try await raw("DELETE", "/api/feeds/\(id)", query: [], body: nil)
    }

    func refreshFeed(_ id: Int) async throws -> Feed {
        let r: FeedEnvelope = try await call("POST", "/api/feeds/\(id)/refresh")
        return r.feed
    }

    // MARK: - ポッドキャスト（段階3）

    func podcasts() async throws -> [Podcast] {
        let r: PodcastList = try await call("GET", "/api/podcasts")
        return r.podcasts
    }

    func addPodcast(url: String) async throws -> AddPodcastResult {
        try await call("POST", "/api/podcasts", body: ["url": url])
    }

    func deletePodcast(_ id: Int) async throws {
        _ = try await raw("DELETE", "/api/podcasts/\(id)", query: [], body: nil)
    }

    /// 番組の回（新しい順）。afterId を渡すとその id より後を昇順で
    func episodes(podcast: Int? = nil, before: String? = nil, afterId: Int? = nil, limit: Int? = nil) async throws -> EpisodePage {
        var q: [URLQueryItem] = []
        if let before { q.append(URLQueryItem(name: "before", value: before)) }
        if let afterId { q.append(URLQueryItem(name: "after_id", value: String(afterId))) }
        if let limit { q.append(URLQueryItem(name: "limit", value: String(limit))) }
        let path = podcast.map { "/api/podcasts/\($0)/episodes" } ?? "/api/episodes"
        return try await call("GET", path, query: q)
    }

    /// 1回の説明（ショーノートの HTML）。無ければ nil
    func episodeNotes(_ id: Int) async throws -> String? {
        let r: EpisodeNotesEnvelope = try await call("GET", "/api/episodes/\(id)")
        return r.episode.description
    }

    /// iTunes Search API で番組を名前で探す（音沙汰の Worker は通さない・認証なし）
    func searchPodcasts(_ term: String) async throws -> [PodcastSearchResult] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "country", value: "JP"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "term", value: term),
        ]
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: c.url!)
        } catch {
            throw APIError.transport((error as NSError).localizedDescription)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.transport("検索できませんでした") }
        do {
            return try JSONDecoder().decode(PodcastSearchResponse.self, from: data).results.filter { $0.feedUrl != nil }
        } catch {
            throw APIError.transport("検索の結果を読めませんでした")
        }
    }

    // MARK: - プッシュ通知の端末

    /// environment: "development"（開発署名）か "production"（TestFlight・App Store）
    func registerDevice(token: String, environment: String) async throws {
        _ = try await raw("PUT", "/api/devices", query: [], body: ["token": token, "environment": environment])
    }

    func unregisterDevice(token: String) async throws {
        _ = try await raw("DELETE", "/api/devices/\(token)", query: [], body: nil)
    }

    // MARK: - 下まわり

    private func call<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
        let data = try await raw(method, path, query: query, body: body)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.transport("応答を読めませんでした")
        }
    }

    private func raw(_ method: String, _ path: String, query: [URLQueryItem], body: [String: Any]?) async throws -> Data {
        guard let base = ServerConfig.baseURL, var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.notConfigured
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if !ServerConfig.isLocalDev {
            guard let id = AccessTokenStore.idValue, let secret = AccessTokenStore.secretValue else {
                throw APIError.notConfigured
            }
            req.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
            req.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req, delegate: noRedirect)
        } catch {
            throw APIError.transport((error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("応答がありません") }
        if (300..<400).contains(http.statusCode) || http.statusCode == 401 || http.statusCode == 403 {
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let e = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "unknown"
            throw APIError.http(http.statusCode, e)
        }
        return data
    }
}
