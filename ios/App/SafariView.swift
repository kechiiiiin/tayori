import SafariServices
import UIKit

/// ② アプリ内の Safari 画面（SFSafariViewController）。
///
/// SwiftUI の sheet／fullScreenCover から出すと、SFSafariViewController 標準の
/// 「左端から右へスワイプで閉じる」（push 風の遷移）が効かなくなる。
/// そこで最前面の UIViewController から UIKit の present(_:animated:) で直接出す。
///
/// 閉じたら（「完了」でも左端スワイプでも）onDone を**ちょうど1回**呼ぶ:
/// - 「完了」→ safariViewControllerDidFinish
/// - スワイプ → didFinish が来ないことがあるので、viewDidDisappear（閉じ終わり）と
///   presentationController の delegate でも拾う
@MainActor
enum SafariPresenter {
    /// 出しているもの（同時に2枚は出さない）
    private static weak var current: TayoriSafariViewController?

    static func present(url: URL, onDone: @escaping () -> Void) {
        guard current == nil, let top = topViewController() else {
            onDone()
            return
        }
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = true
        let vc = TayoriSafariViewController(url: url, configuration: config)
        vc.dismissButtonStyle = .done
        vc.onDone = onDone
        vc.delegate = vc
        current = vc
        top.present(vc, animated: true) {
            vc.presentationController?.delegate = vc
        }
    }

    /// いちばん上に出ている画面（シートが出ていればその上に重ねる）
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var vc = window?.rootViewController
        while let next = vc?.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc
    }
}

final class TayoriSafariViewController: SFSafariViewController, SFSafariViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    var onDone: (() -> Void)?

    /// onDone を1回だけ呼ぶ
    private func finish() {
        guard let done = onDone else { return }
        onDone = nil
        done()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 左端スワイプ・「完了」どちらでも、閉じ終わるとここに来る（presentingViewController が外れている）
        if isBeingDismissed || presentingViewController == nil { finish() }
    }

    /// 「完了」
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) { finish() }

    /// シート風に下へ払って閉じた場合
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish() }
}
