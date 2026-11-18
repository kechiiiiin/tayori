import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 共有拡張の入口。Safari などから受け取った URL を ShareView に渡す
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        Task { @MainActor [weak self] in
            guard let self else { return }
            let url = await Self.sharedURL(from: extensionContext)
            let context = extensionContext
            let host = UIHostingController(rootView: ShareView(url: url?.absoluteString) {
                context?.completeRequest(returningItems: nil)
            }.tint(Theme.accent))
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            host.didMove(toParent: self)
        }
    }

    /// 添付の中から http(s) の URL を探す（URL そのもの → 文字の中の URL）
    static func sharedURL(from context: NSExtensionContext?) async -> URL? {
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, isWeb(u) { return u }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String, let u = firstURL(in: s) { return u }
        }
        return nil
    }

    private static func isWeb(_ u: URL) -> Bool { u.scheme == "http" || u.scheme == "https" }

    private static func firstURL(in s: String) -> URL? {
        let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let m = d?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        return m?.url.flatMap { isWeb($0) ? $0 : nil }
    }
}
