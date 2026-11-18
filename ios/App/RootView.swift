import SwiftUI

/// iPhone（幅が狭い）は一覧ひとつ。iPad・Mac（幅が広い）は左にカテゴリとサイトのサイドバー
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var path: [Route] = []
    @State private var demoApplied = false
    @State private var sharePreview: String?

    enum Route: Hashable { case sites, settings }

    var body: some View {
        Group {
            if !model.isConfigured {
                NavigationStack { SettingsView(firstRun: true) }
            } else if sizeClass == .regular {
                NavigationSplitView {
                    SidebarView()
                } detail: {
                    NavigationStack { ItemListView(showCategoryBar: false) }
                }
            } else {
                NavigationStack(path: $path) {
                    ItemListView(showCategoryBar: true)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { path.append(.sites) } label: {
                                    Image(systemName: "line.3.horizontal")
                                }
                                .accessibilityLabel("サイト")
                            }
                        }
                        .navigationDestination(for: Route.self) { r in
                            switch r {
                            case .sites: SitesView(onPickFeed: { _ in path.removeAll() })
                            case .settings: SettingsView(firstRun: false)
                            }
                        }
                }
            }
        }
        .fullScreenCover(item: Binding(get: { model.presented }, set: { model.presented = $0 }), onDismiss: nil) { item in
            if let url = item.link {
                SafariView(url: url) {
                    model.presented = nil
                    model.returned(from: item)
                }
                .ignoresSafeArea()
            }
        }
        .sheet(item: Binding(get: { model.commentTarget }, set: { model.commentTarget = $0 })) { item in
            CommentSheet(item: item, initial: model.commentDraft ?? item.comment ?? "")
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(get: { sharePreview != nil }, set: { if !$0 { sharePreview = nil } })) {
            ShareView(url: sharePreview) { sharePreview = nil }
                .presentationDetents([.medium])
        }
        .task {
            await model.reload()
            applyDemo()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.reload() } }
        }
    }

    /// DEBUG のスクリーンショット用: 起動引数で画面の状態を作る
    ///   -tayoriTab unread|commented|all  -tayoriScreen sites  -tayoriDemo opened|comment  -tayoriSharePreview <URL>
    private func applyDemo() {
        #if DEBUG
        guard !demoApplied else { return }
        demoApplied = true
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.index(after: i) < args.endIndex else { return nil }
            return args[args.index(after: i)]
        }
        if let t = value("-tayoriTab"), let s = ItemState(rawValue: t), s != model.state {
            model.select(state: s)
        }
        if value("-tayoriScreen") == "sites", sizeClass != .regular { path = [.sites] }
        if let u = value("-tayoriSharePreview") { sharePreview = u }
        if let d = value("-tayoriDemo"), let first = model.items.first {
            model.lastOpened = first
            if d == "comment" {
                model.commentDraft = "二つ目の問い（「先週から何が変わった？」）は来週のチームの 1on1 で試す。"
                model.commentTarget = first
            }
        }
        #endif
    }
}
