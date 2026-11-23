import SwiftUI
import UIKit

/// キューの中身のリスト（UIKit の UICollectionView）。
/// - 各行の右端の取っ手（≡）をつかんでドラッグすれば、編集モードに入らずに並べ替えられる（UICellAccessory.reorder・常に表示）
/// - 行のスワイプ操作は持たない。外す・別のキューへ移すは長押しメニュー（EpisodeRow の contextMenu）
/// - 行のタップは詳細ページ・アートワークのタップは番組の画面・長押しはキューのメニュー（行の中身は SwiftUI の EpisodeRow）
/// - どこを左右に払っても（行の上でも余白でも）隣のタブへ（environment の tabSwipe へ渡す）。ただし右端の取っ手の上で始めたドラッグは並べ替え
/// SwiftUI の List は取っ手を出すのに編集モードが要るので UIKit にした
struct QueueCollectionView: UIViewRepresentable {
    let queue: PodcastQueue

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        let c = context.coordinator
        c.queueId = queue.id
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = .clear
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
        c.tabSwipe = context.environment.tabSwipe
        c.installTabPan(on: cv)
        c.configure(cv)
        c.apply(queue, animated: false)
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        let c = context.coordinator
        c.tabSwipe = context.environment.tabSwipe
        c.queueId = queue.id
        c.apply(queue, animated: true)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var queueId = UUID()
        var tabSwipe: TabSwipeHandler?
        private weak var tabPan: UIPanGestureRecognizer?
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

        /// 取っ手（右端の UICellAccessory.reorder）の幅。この中で始まったパンはタブに使わず、並べ替えのドラッグに任せる
        static let handleWidth: CGFloat = 60

        /// 取っ手の上以外で始まったパンを拾い、指の動きを親のタブ切り替えへ渡す（追従・確定の決まりは TabSwipe）。
        /// 縦のスクロールとは同時に認識する（記事の一覧の simultaneousGesture と同じ）
        func installTabPan(on cv: UICollectionView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTabPan(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            cv.addGestureRecognizer(pan)
            tabPan = pan
        }

        @objc private func handleTabPan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            let size = CGSize(width: t.x, height: t.y)
            switch g.state {
            case .changed: tabSwipe?.changed(size)
            case .ended: tabSwipe?.ended(size)
            case .cancelled, .failed: tabSwipe?.ended(.zero)
            default: break
            }
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === tabPan, let cv = g.view as? UICollectionView else { return true }
            // 右端の取っ手の上で始まったら並べ替えのドラッグに任せる（行の上でも余白でもそれ以外はタブ切り替え）
            let x = g.location(in: cv).x
            if cv.indexPathForItem(at: g.location(in: cv)) != nil, x > cv.bounds.width - Self.handleWidth { return false }
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            g === tabPan
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
    }
}
