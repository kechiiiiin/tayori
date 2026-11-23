import SwiftUI

/// 一覧の左右スワイプで隣のタブへ切り替える決まり（記事のカテゴリとポッドキャストの上のタブで共通）。
/// - 左へで右隣・右へで左隣。ドラッグ中は指に追従し（0.6 倍）、端のタブではゴムのように軽くしか動かない（0.2 倍）
/// - 縦のスクロールを邪魔しないよう、横の動きが縦より大きいあいだだけ追従し、
///   確定は横が 60pt 以上・縦の倍以上のときだけ
enum TabSwipe {
    static let duration = 0.28
    static let minimumDistance: CGFloat = 24
    static let commitDistance: CGFloat = 60

    /// 指の向き → 動く先（左へ = +1 で右隣・右へ = -1 で左隣）
    static func delta(dx: CGFloat) -> Int { dx < 0 ? 1 : -1 }

    /// ドラッグ中の一覧の横のずれ。縦が勝っている・動き始め（24pt 未満）のあいだは nil（前のずれのまま）
    static func followOffset(dx: CGFloat, dy: CGFloat, canMove: (Int) -> Bool) -> CGFloat? {
        guard hypot(dx, dy) >= minimumDistance, abs(dx) > abs(dy) else { return nil }
        let damping: CGFloat = canMove(delta(dx: dx)) ? 0.6 : 0.2
        return dx * damping
    }

    /// 指を離したとき、隣へ切り替えるか
    static func shouldCommit(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dx) >= commitDistance && abs(dx) > abs(dy) * 2
    }
}

/// 選んだタブの下線。matchedGeometryEffect で前のタブから滑って動く（アニメは呼ぶ側の .animation で）
struct TabUnderline: View {
    let on: Bool
    let namespace: Namespace.ID

    var body: some View {
        ZStack {
            Color.clear.frame(height: 2)
            if on {
                Rectangle().fill(Theme.accent).frame(height: 2)
                    .matchedGeometryEffect(id: "underline", in: namespace)
            }
        }
    }
}

/// 一覧の上の横スワイプを、タブを持つ親（PodcastRootView）へ渡す口。指の動き（開始点からのずれ）をそのまま渡す
struct TabSwipeHandler {
    var changed: (CGSize) -> Void
    var ended: (CGSize) -> Void
}

extension EnvironmentValues {
    @Entry var tabSwipe: TabSwipeHandler? = nil
}

extension View {
    /// この一覧の上の左右スワイプで隣のタブへ（親が environment の tabSwipe を入れているときだけ効く）。
    /// reservesForward: 左へのスワイプ（右隣へ）は行のスワイプ操作に譲り、一覧は動かさない
    func tabSwipeGesture(reservesForward: Bool = false) -> some View {
        modifier(TabSwipeGestureModifier(reservesForward: reservesForward))
    }
}

private struct TabSwipeGestureModifier: ViewModifier {
    @Environment(\.tabSwipe) private var handler
    let reservesForward: Bool

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: TabSwipe.minimumDistance, coordinateSpace: .local)
                .onChanged { v in handler?.changed(filtered(v.translation)) }
                .onEnded { v in handler?.ended(filtered(v.translation)) }
        )
    }

    private func filtered(_ t: CGSize) -> CGSize {
        reservesForward ? CGSize(width: max(0, t.width), height: t.height) : t
    }
}
