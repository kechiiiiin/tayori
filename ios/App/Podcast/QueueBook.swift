import Foundation

/// キュー（メイン・サブ…）。1つの回はどれか1つのキューにだけ入る
struct PodcastQueue: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var episodes: [Episode]
}

/// 番組ごとの自動追加: 入れない（既定）／あるキューの先頭か末尾へ
enum AutoAdd: Codable, Hashable, Sendable {
    case off
    case queue(UUID, atTop: Bool)
}

/// キューの並びと中身。画面・再生・保存から切り離した純粋なロジック（TayoriTests で確かめる）
struct QueueBook: Codable, Equatable, Sendable {
    var queues: [PodcastQueue]

    static let maxNameLength = 20

    /// 初めて開いたときの並び
    static func initial() -> QueueBook {
        QueueBook(queues: [
            PodcastQueue(id: UUID(), name: "メイン", episodes: []),
            PodcastQueue(id: UUID(), name: "サブ", episodes: []),
        ])
    }

    // MARK: - 引く

    func queue(_ id: UUID) -> PodcastQueue? { queues.first { $0.id == id } }
    func index(of id: UUID) -> Int? { queues.firstIndex { $0.id == id } }

    /// その回が入っているキューと位置
    func location(of episodeId: Int) -> (queue: UUID, index: Int)? {
        for q in queues {
            if let i = q.episodes.firstIndex(where: { $0.id == episodeId }) { return (q.id, i) }
        }
        return nil
    }

    func contains(_ episodeId: Int) -> Bool { location(of: episodeId) != nil }

    /// どこかのキューに入っている回（キューの並び順）
    var allEpisodes: [Episode] { queues.flatMap(\.episodes) }

    // MARK: - キューそのもの

    @discardableResult
    mutating func createQueue(name: String) -> UUID? {
        guard let n = Self.normalize(name) else { return nil }
        let q = PodcastQueue(id: UUID(), name: n, episodes: [])
        queues.append(q)
        return q.id
    }

    mutating func rename(_ id: UUID, to name: String) {
        guard let i = index(of: id), let n = Self.normalize(name) else { return }
        queues[i].name = n
    }

    /// 左右へ（delta = -1 で左・+1 で右）。端では止まる
    mutating func moveQueue(_ id: UUID, by delta: Int) {
        guard let i = index(of: id) else { return }
        let j = i + delta
        guard queues.indices.contains(j) else { return }
        queues.swapAt(i, j)
    }

    /// 消す（中の回もキューから外れる）。最後の1つは消さない
    mutating func deleteQueue(_ id: UUID) {
        guard queues.count > 1, let i = index(of: id) else { return }
        queues.remove(at: i)
    }

    static func normalize(_ name: String) -> String? {
        let s = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count <= maxNameLength else { return nil }
        return s
    }

    // MARK: - 回の出し入れ

    /// キューの先頭／末尾へ入れる。もう別の（同じ）キューにあれば、そこから移す
    mutating func add(_ episode: Episode, to queueId: UUID, atTop: Bool) {
        guard index(of: queueId) != nil else { return }
        remove(episode.id)
        let i = index(of: queueId)!
        if atTop { queues[i].episodes.insert(episode, at: 0) } else { queues[i].episodes.append(episode) }
    }

    /// キューから外す
    mutating func remove(_ episodeId: Int) {
        for i in queues.indices { queues[i].episodes.removeAll { $0.id == episodeId } }
    }

    /// キューの中の並べ替え（List の onMove の形）
    mutating func move(in queueId: UUID, from source: IndexSet, to destination: Int) {
        guard let i = index(of: queueId) else { return }
        var eps = queues[i].episodes
        let moving = source.sorted().filter { eps.indices.contains($0) }.map { eps[$0] }
        let before = source.filter { $0 < destination }.count
        for idx in source.sorted(by: >) where eps.indices.contains(idx) { eps.remove(at: idx) }
        let at = max(0, min(eps.count, destination - before))
        eps.insert(contentsOf: moving, at: at)
        queues[i].episodes = eps
    }

    // MARK: - 聴き終えたとき

    /// 聴き終えた回をキューから外し、次に再生する回を返す。
    /// 次 = その回が入っていたキュー（無ければ playingFrom、それも無ければ最初のキュー）の先頭。
    /// そこが空なら右隣のキューの先頭へ（空のキューは飛ばす）。最後のキューまで空なら nil（止まる）
    mutating func finish(_ episodeId: Int, playingFrom: UUID?) -> (episode: Episode, queue: UUID)? {
        let from = location(of: episodeId)?.queue ?? playingFrom
        remove(episodeId)
        let start = from.flatMap { index(of: $0) } ?? 0
        guard queues.indices.contains(start) else { return nil }
        for j in start..<queues.count {
            if let head = queues[j].episodes.first { return (head, queues[j].id) }
        }
        return nil
    }

    // MARK: - 自動追加

    /// 番組の新着をその番組の設定に従って入れる。fresh は id の昇順（古い→新しい）。
    /// 入れるのは since より新しい回だけ（過去回が後から足されたときにまとめて入らないように）・もうどこかのキューにある回は動かさない。
    /// 先頭へ入れるときも、新しい回が上に来る（古い順に1つずつ先頭へ）。入れた数を返す
    @discardableResult
    mutating func autoAdd(_ fresh: [Episode], setting: AutoAdd, since: Date) -> Int {
        guard case let .queue(qid, atTop) = setting, index(of: qid) != nil else { return 0 }
        let picked = fresh
            .filter { (When.date($0.publishedAt ?? $0.sortAt) ?? .distantPast) >= since && !contains($0.id) }
            .sorted { ($0.publishedAt ?? $0.sortAt, $0.id) < ($1.publishedAt ?? $1.sortAt, $1.id) }
        for e in picked { add(e, to: qid, atTop: atTop) }
        return picked.count
    }
}
