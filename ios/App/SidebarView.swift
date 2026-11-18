import SwiftUI

/// iPad・Mac の左: カテゴリ（未読数）とサイト。選ぶと右の一覧が絞られる
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var showSites = false
    @State private var removing: Feed?

    enum Pick: Hashable { case all, category(Int), none, feed(Int) }

    private var selection: Binding<Pick?> {
        Binding {
            if let f = model.feedFilter { return .feed(f.id) }
            switch model.category {
            case .all: return .all
            case .category(let id): return .category(id)
            case .none: return Pick.none
            }
        } set: { p in
            switch p {
            case .all?, nil: model.select(category: .all)
            case .category(let id)?: model.select(category: .category(id))
            case .none?: model.select(category: .none)
            case .feed(let id)?: if let f = model.feeds.first(where: { $0.id == id }) { model.select(feed: f) }
            }
        }
    }

    var body: some View {
        List(selection: selection) {
            Section("カテゴリ") {
                row("すべて", "tray.full", model.count(model.categories.total)).tag(Pick.all)
                ForEach(model.categories.categories) { c in
                    row(c.name, "folder", model.count(c.counts)).tag(Pick.category(c.id))
                }
                row("未分類", "tray", model.count(model.categories.uncategorized)).tag(Pick.none)
            }
            ForEach(groups, id: \.title) { g in
                Section(g.title) {
                    ForEach(g.feeds) { f in
                        FeedRow(feed: f)
                            .tag(Pick.feed(f.id))
                            .contextMenu { FeedMenu(feed: f) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { removing = f } label: { Text("外す") }
                            }
                    }
                }
            }
        }
        .navigationTitle("便り")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSites = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("サイトを足す・整理する")
            }
        }
        .sheet(isPresented: $showSites) {
            NavigationStack {
                SitesView(onPickFeed: { _ in showSites = false })
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("閉じる") { showSites = false } }
                    }
            }
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
    }

    private struct Group { let title: String; let feeds: [Feed] }

    /// サイトをカテゴリの並びで
    private var groups: [Group] {
        var out = model.categories.categories.map { Group(title: $0.name, feeds: model.feeds(in: $0.id)) }
        out.append(Group(title: "未分類", feeds: model.feeds(in: nil)))
        return out.filter { !$0.feeds.isEmpty }
    }

    private func row(_ title: String, _ icon: String, _ n: Int) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if n > 0 { Text("\(n)").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
