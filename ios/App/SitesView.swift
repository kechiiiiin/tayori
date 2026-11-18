import SwiftUI

/// ⑥ サイト: カテゴリごとにまとめて並ぶ。URL を貼ると RSS を探して足す。
/// 長押しでカテゴリを付け替え、左へスワイプで外す。取れないサイトには印。タップでそのサイトの記事だけを一覧に出す
struct SitesView: View {
    @Environment(AppModel.self) private var model
    var onPickFeed: (Feed) -> Void = { _ in }

    @State private var url = ""
    @State private var addCategory: Int?
    @State private var adding = false
    @State private var outcome: AppModel.AddOutcome?
    @State private var nameEditor: NameEditor?
    @State private var removing: Feed?
    @State private var removingCategory: Category?

    var body: some View {
        List {
            Section {
                addBox.listRowSeparator(.hidden)
            }
            ForEach(model.categories.categories) { c in
                Section {
                    feedRows(model.feeds(in: c.id))
                } header: {
                    categoryHeader(c)
                }
            }
            Section {
                feedRows(model.feeds(in: nil))
            } header: {
                header(title: "未分類", unread: model.categories.uncategorized.unread)
            }
            if let e = model.errorMessage {
                Text(e).font(.footnote).foregroundStyle(Theme.error)
            }
        }
        .listStyle(.plain)
        .navigationTitle("サイト")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { nameEditor = NameEditor(target: nil, name: "") } label: { Label("カテゴリを作る", systemImage: "folder.badge.plus") }
                    NavigationLink { SettingsView(firstRun: false) } label: { Label("接続の設定", systemImage: "gearshape") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("カテゴリを作る・設定")
            }
        }
        .refreshable { await model.reload() }
        .sheet(item: $nameEditor) { e in
            CategoryNameSheet(editor: e).presentationDetents([.height(220)])
        }
        .confirmationDialog(
            "「\(removing?.title ?? "")」を外しますか？",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("外す（記事とコメントも消えます）", role: .destructive) {
                if let f = removing { Task { await model.deleteFeed(f) } }
                removing = nil
            }
        }
        .confirmationDialog(
            "カテゴリ「\(removingCategory?.name ?? "")」を消しますか？",
            isPresented: Binding(get: { removingCategory != nil }, set: { if !$0 { removingCategory = nil } }),
            titleVisibility: .visible
        ) {
            Button("消す（中のサイトは未分類へ）", role: .destructive) {
                if let c = removingCategory { Task { await model.deleteCategory(c) } }
                removingCategory = nil
            }
        }
    }

    // MARK: - URL を貼って足す

    private var addBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            IMESafeTextField(text: $url, placeholder: "サイトか RSS の URL を貼る", keyboard: .URL, returnKey: .go) { add() }
                .frame(height: 22)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(uiColor: .separator), lineWidth: 1))
            if !url.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("カテゴリ").font(.caption).foregroundStyle(.secondary)
                CategoryPicker(categories: model.categories.categories, selection: $addCategory) {
                    nameEditor = NameEditor(target: nil, name: "")
                }
                Button { add() } label: {
                    HStack {
                        if adding { ProgressView().tint(.white) }
                        Text(adding ? "RSS を探しています…" : "足す").font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(adding)
            }
            if let o = outcome { AddOutcomeView(outcome: o) }
        }
        .padding(.vertical, 4)
    }

    private func add() {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !adding else { return }
        adding = true
        outcome = nil
        Task {
            let r = await model.addFeed(url: u, categoryId: addCategory)
            adding = false
            outcome = r
            if case .failed = r {} else { url = "" }
        }
    }

    // MARK: - 見出し

    private func categoryHeader(_ c: Category) -> some View {
        HStack {
            header(title: c.name, unread: c.unread)
            Spacer()
            Menu {
                Button { nameEditor = NameEditor(target: c, name: c.name) } label: { Label("名前を変える", systemImage: "pencil") }
                Button { Task { await model.moveCategory(c, by: -1) } } label: { Label("上へ", systemImage: "arrow.up") }
                Button { Task { await model.moveCategory(c, by: 1) } } label: { Label("下へ", systemImage: "arrow.down") }
                Button(role: .destructive) { removingCategory = c } label: { Label("消す", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.caption).padding(6)
            }
            .accessibilityLabel("\(c.name) の操作")
        }
    }

    private func header(title: String, unread: Int) -> some View {
        Text(unread > 0 ? "\(title)　· 未読 \(unread)" : title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    // MARK: - サイトの行

    @ViewBuilder
    private func feedRows(_ feeds: [Feed]) -> some View {
        ForEach(feeds) { f in
            FeedRow(feed: f)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.select(feed: f)
                    onPickFeed(f)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { removing = f } label: { Text("外す") }
                }
                .contextMenu { FeedMenu(feed: f) }
        }
    }
}

/// 長押しのメニュー（サイト画面と iPad のサイドバーで共通）
struct FeedMenu: View {
    @Environment(AppModel.self) private var model
    let feed: Feed

    var body: some View {
        Menu {
            ForEach(model.categories.categories) { c in
                Button { Task { await model.moveFeed(feed, to: c.id) } } label: {
                    if feed.categoryId == c.id { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
            Button { Task { await model.moveFeed(feed, to: nil) } } label: {
                if feed.categoryId == nil { Label("未分類", systemImage: "checkmark") } else { Text("未分類") }
            }
        } label: {
            Label("カテゴリを付け替える", systemImage: "folder")
        }
        Button { Task { await model.refreshFeed(feed) } } label: { Label("いますぐ取りに行く", systemImage: "arrow.clockwise") }
        if let e = feed.lastError {
            Text("取得できません（\(e)）")
        }
    }
}

/// サイトの1行: 頭文字・名前・URL・未読数（取れないときは赤い印）
struct FeedRow: View {
    let feed: Feed

    var body: some View {
        HStack(spacing: 10) {
            Text(feed.initial)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(feed.title).font(.subheadline).lineLimit(1)
                Text(feed.displayURL).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if feed.lastError != nil {
                Text("取得できません").font(.caption).foregroundStyle(Theme.error)
            } else if feed.unread > 0 {
                Text("未読 \(feed.unread)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 足した結果（✓ 追加しました／RSS が見つかりませんでした）
struct AddOutcomeView: View {
    let outcome: AppModel.AddOutcome

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark" : "exclamationmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(ok ? Theme.readGreen : Theme.error, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                if let d = detail { Text(d).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var ok: Bool {
        if case .failed = outcome { return false }
        return true
    }
    private var title: String {
        switch outcome {
        case .added: return "追加しました"
        case .exists: return "もう購読しています"
        case .failed(let m): return m
        }
    }
    private var detail: String? {
        switch outcome {
        case .added(let t, let c): return "\(t) → \(c)"
        case .exists(let t): return t
        case .failed: return nil
        }
    }
}

/// カテゴリの名前（作る・変える）
struct NameEditor: Identifiable {
    let id = UUID()
    let target: Category?
    var name: String
}

struct CategoryNameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let editor: NameEditor
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.target == nil ? "カテゴリを作る" : "名前を変える").font(.headline)
            IMESafeTextField(text: $name, placeholder: "例: 仕事", returnKey: .done) { save() }
                .frame(height: 22)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(uiColor: .separator), lineWidth: 1))
            HStack(spacing: 8) {
                Button("やめる") { dismiss() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12))
                Button(editor.target == nil ? "作る" : "変える") { save() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
        }
        .padding(16)
        .onAppear { name = editor.name }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        Task {
            if let c = editor.target { await model.renameCategory(c, to: n) } else { await model.createCategory(n) }
            dismiss()
        }
    }
}
