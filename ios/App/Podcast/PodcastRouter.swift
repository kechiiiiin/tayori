import Observation
import SwiftUI

/// ポッドキャストのページの行き先（NavigationStack の path）
enum PodcastRoute: Hashable {
    case show(Podcast)
    case episode(Episode)
}

/// ポッドキャストのページの画面の行き来。行・詳細・全画面プレーヤー（下のタブの外）から使う
@MainActor
@Observable
final class PodcastRouter {
    static let shared = PodcastRouter()

    var path: [PodcastRoute] = []
    /// 増えたら下のタブをポッドキャストへ切り替える（RootView が見る）
    private(set) var showTabRequest = 0

    /// 回の詳細ページへ
    func openEpisode(_ e: Episode) {
        path.append(.episode(e))
    }

    /// 番組の画面へ。すぐ手前がその番組の画面なら戻るだけ（番組 → 回 → 番組 と重ねない）
    func openShow(feedId: Int) {
        showTabRequest += 1
        if path.count >= 2, case let .show(p) = path[path.count - 2], p.id == feedId {
            path.removeLast()
            return
        }
        if case let .show(p) = path.last, p.id == feedId { return }
        let store = PodcastStore.shared
        if let p = store.podcasts.first(where: { $0.id == feedId }) {
            path.append(.show(p))
            return
        }
        // 番組の一覧をまだ読んでいない
        Task {
            await store.refresh()
            if let p = store.podcasts.first(where: { $0.id == feedId }) { path.append(.show(p)) }
        }
    }
}
