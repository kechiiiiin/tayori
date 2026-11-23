import SwiftUI
import UIKit

/// キューの中身のリスト（UIKit の UICollectionView）。
/// - 各行の右端の取っ手（≡）をつかんでドラッグすれば、編集モードに入らずに並べ替えられる（UICellAccessory.reorder・常に表示）
/// - 左へスワイプで外す（いっぱいに払えばそのまま）・右へスワイプで別のキューへ移す
/// - 行のタップは詳細ページ・アートワークのタップは番組の画面・長押しはキューのメニュー（行の中身は SwiftUI の EpisodeRow）
/// SwiftUI の List は取っ手を出すのに編集モードが要り、編集モードではスワイプが効かないので UIKit にした
struct QueueCollectionView: UIViewRepresentable {
    let queue: PodcastQueue
    /// 右へスワイプの「移す」
    var onMoveRequest: (Episode) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        let c = context.coordinator
        c.queueId = queue.id
        c.onMoveRequest = onMoveRequest
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = .clear
        config.trailingSwipeActionsConfigurationProvider = { [weak c] ip in c?.trailingSwipe(ip) }
        config.leadingSwipeActionsConfigurationProvider = { [weak c] ip in c?.leadingSwipe(ip) }
        let cv = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        cv.backgroundColor = .clear
        // タップは行の中身（SwiftUI）が受ける（詳細ページ・アートワークは番組）。セルの選択は使わない
        cv.allowsSelection = false
        cv.accessibilityIdentifier = "queueList"
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak refresh] _ in
            Task { @MainActor in
                await PodcastStore.shared.refresh()
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        cv.refreshControl = refresh
        c.configure(cv)
        c.apply(queue, animated: false)
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        let c = context.coordinator
        c.onMoveRequest = onMoveRequest
        c.queueId = queue.id
        c.apply(queue, animated: true)
    }

    @MainActor
    final class Coordinator: NSObject {
        var queueId = UUID()
        var onMoveRequest: (Episode) -> Void = { _ in }
        private var episodes: [Int: Episode] = [:]
        private var dataSource: UICollectionViewDiffableDataSource<Int, Int>!

        func configure(_ cv: UICollectionView) {
            let reg = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { [weak self] cell, _, id in
                guard let self, let e = self.episodes[id] else { return }
                let qid = self.queueId
                cell.contentConfiguration = UIHostingConfiguration {
                    EpisodeRow(episode: e, inQueue: qid)
                }
                .margins(.vertical, 8)
                cell.accessories = [.reorder(displayed: .always, options: .init(showsVerticalSeparator: false))]
                cell.backgroundConfiguration = .clear()
                cell.accessibilityIdentifier = "queueRow-\(e.id)"
            }
            dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: cv) { cv, ip, id in
                cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: id)
            }
            dataSource.reorderingHandlers.canReorderItem = { _ in true }
            dataSource.reorderingHandlers.didReorder = { [weak self] tx in
                guard let self else { return }
                PodcastStore.shared.reorder(in: self.queueId, to: tx.finalSnapshot.itemIdentifiers)
            }
        }

        func apply(_ queue: PodcastQueue, animated: Bool) {
            for e in queue.episodes { episodes[e.id] = e }
            let ids = queue.episodes.map(\.id)
            guard dataSource.snapshot().itemIdentifiers != ids else { return }
            var snap = NSDiffableDataSourceSnapshot<Int, Int>()
            snap.appendSections([0])
            snap.appendItems(ids)
            dataSource.apply(snap, animatingDifferences: animated)
        }

        private func episode(at ip: IndexPath) -> Episode? {
            dataSource.itemIdentifier(for: ip).flatMap { episodes[$0] }
        }

        func trailingSwipe(_ ip: IndexPath) -> UISwipeActionsConfiguration? {
            guard let e = episode(at: ip) else { return nil }
            let remove = UIContextualAction(style: .destructive, title: "外す") { _, _, done in
                PodcastStore.shared.remove(e.id)
                done(true)
            }
            remove.image = UIImage(systemName: "minus.circle")
            let c = UISwipeActionsConfiguration(actions: [remove])
            c.performsFirstActionWithFullSwipe = true
            return c
        }

        func leadingSwipe(_ ip: IndexPath) -> UISwipeActionsConfiguration? {
            guard let e = episode(at: ip), PodcastStore.shared.queues.count > 1 else { return nil }
            let move = UIContextualAction(style: .normal, title: "移す") { [weak self] _, _, done in
                self?.onMoveRequest(e)
                done(true)
            }
            move.image = UIImage(systemName: "arrow.right.arrow.left")
            move.backgroundColor = UIColor(Theme.readGreen)
            let c = UISwipeActionsConfiguration(actions: [move])
            c.performsFirstActionWithFullSwipe = false
            return c
        }
    }
}
