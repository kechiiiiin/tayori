import SwiftUI

/// ⑦ Safari の共有から足す画面（共有拡張の中身。DEBUG ではアプリからも出せる）。
/// カテゴリを選んで「追加」→ POST /api/feeds → 「追加しました（サイト名 → カテゴリ）」か「RSS が見つかりませんでした」
struct ShareView: View {
    /// 共有されたページの URL（取れなかったら nil）
    let url: String?
    let onClose: () -> Void

    @State private var categories: [Category] = []
    @State private var selection: Int?
    @State private var newName = ""
    @State private var creating = false
    @State private var phase: Phase = .idle
    @State private var loadError: String?
    @State private var autoClose = true

    enum Phase: Equatable {
        case idle, adding
        case done(title: String, category: String, created: Bool)
        case failed(String)
    }

    private let api = TayoriAPI.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("便りに追加").font(.headline)
                Spacer()
                Button(isDone ? "閉じる" : "やめる", action: onClose)
            }
            if let url {
                Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("URL を受け取れませんでした").font(.subheadline).foregroundStyle(Theme.error)
            }
            if !isDone {
                Text("カテゴリ").font(.caption).foregroundStyle(.secondary)
                CategoryPicker(categories: categories, selection: $selection) { creating = true }
                if creating {
                    HStack(spacing: 8) {
                        IMESafeTextField(text: $newName, placeholder: "新しいカテゴリの名前", returnKey: .done) { createCategory() }
                            .frame(height: 22)
                            .padding(8)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(uiColor: .separator), lineWidth: 1))
                        Button("作る") { createCategory() }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let e = loadError { Text(e).font(.caption).foregroundStyle(Theme.error) }
                Button { add() } label: {
                    HStack {
                        if phase == .adding { ProgressView().tint(.white) }
                        Text(phase == .adding ? "RSS を探しています…" : "追加").font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(url == nil || phase == .adding)
            }
            result
            Spacer(minLength: 0)
        }
        .padding(16)
        .task {
            await loadCategories()
            #if DEBUG
            // スクリーンショット用: -tayoriShareAutoAdd <カテゴリ名> でそのカテゴリを選んで追加まで進める
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-tayoriShareAutoAdd"), args.index(after: i) < args.endIndex {
                let name = args[args.index(after: i)]
                selection = categories.first { $0.name == name }?.id
                autoClose = false
                add()
            }
            #endif
        }
    }

    private var isDone: Bool {
        if case .done = phase { return true }
        return false
    }

    @ViewBuilder
    private var result: some View {
        switch phase {
        case .done(let title, let category, let created):
            toast(ok: true, title: created ? "追加しました" : "もう購読しています", detail: "\(title) → \(category)")
        case .failed(let m):
            toast(ok: false, title: m, detail: nil)
        default:
            EmptyView()
        }
    }

    private func toast(ok: Bool, title: String, detail: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark" : "exclamationmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(ok ? Theme.readGreen : Theme.error, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func loadCategories() async {
        guard api.isConfigured else {
            loadError = APIError.notConfigured.localizedDescription
            return
        }
        do {
            categories = try await api.categories().categories
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func createCategory() {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        Task {
            do {
                let c = try await api.createCategory(n)
                categories.append(c)
                selection = c.id
                newName = ""
                creating = false
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func add() {
        guard let url, phase != .adding else { return }
        phase = .adding
        Task {
            do {
                let r = try await api.addFeed(url: url, categoryId: selection)
                let cat = categories.first { $0.id == r.feed.categoryId }?.name ?? "未分類"
                phase = .done(title: r.feed.title, category: cat, created: r.created)
                guard autoClose else { return }
                try? await Task.sleep(for: .seconds(1.6))
                onClose()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
