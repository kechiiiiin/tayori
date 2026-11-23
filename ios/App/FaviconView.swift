import SwiftUI
import UIKit

/// ファビコンのメモリキャッシュ（スクロールで同じ URL を何度も読み直さない）
@MainActor
final class FaviconCache {
    static let shared = FaviconCache()
    private let cache = NSCache<NSURL, UIImage>()

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func set(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

/// サイトのファビコン。取得中・失敗時は頭文字の角丸四角を出す
struct FaviconView: View {
    let url: URL?
    let fallback: String
    var size: CGFloat = 28

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(fallback)
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(image == nil ? Theme.chip : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
        .task(id: url) { await load() }
    }

    private func load() async {
        image = nil
        guard let url else { return }
        if let cached = FaviconCache.shared.image(for: url) {
            image = cached
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let loaded = UIImage(data: data) else { return }
        FaviconCache.shared.set(loaded, for: url)
        // task(id:) がキャンセルされていれば（URL が変わった等）反映しない
        if !Task.isCancelled { image = loaded }
    }
}
