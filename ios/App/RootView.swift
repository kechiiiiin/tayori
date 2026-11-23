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
        // アプリ内 Safari は SwiftUI の fullScreenCover ではなく UIKit の present で出す（左端スワイプで閉じられるように・SafariView.swift）
        .onChange(of: model.presented?.id) { _, id in
            guard id != nil, let item = model.presented else { return }
            guard let url = item.link else {
                model.presented = nil
                return
            }
            SafariPresenter.present(url: url) {
                model.presented = nil
                model.returned(from: item)
            }
        }
        .sheet(item: Binding(get: { model.commentTarget }, set: { model.commentTarget = $0 })) { item in
            CommentSheet(item: item, initial: model.commentDraft ?? item.comment ?? "")
                .presentationDetents([.medium, .large])
                .presentationBackground(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: Binding(get: { sharePreview != nil }, set: { if !$0 { sharePreview = nil } })) {
            ShareView(url: sharePreview) { sharePreview = nil }
                .presentationDetents([.medium])
                .presentationBackground(Color(uiColor: .systemBackground))
        }
        .task {
            await model.reload()
            await applyDemo()
            // 通知: 許可を求めて端末を登録し、起動前にタップされた通知の記事があれば開く（Push.swift）
            await PushManager.shared.attach(model)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.reload() } }
        }
    }

    /// DEBUG のスクリーンショット用: 起動引数で画面の状態を作る
    ///   -tayoriTab unread|commented|all  -tayoriScreen sites  -tayoriDemo opened|comment|safari|listcomment  -tayoriSharePreview <URL>
    private func applyDemo() async {
        #if DEBUG
        guard !demoApplied else { return }
        demoApplied = true
        let args = ProcessInfo.processInfo.arguments
        // 起動直後は scenePhase の読み直しと重なるので、一覧が埋まるまで待つ（最大 5 秒）
        for _ in 0..<50 where model.items.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
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
            if d == "safari" { model.presented = first; return }
            if d == "listcomment" { model.commentDraft = nil; model.commentTarget = first; return }
            model.lastOpened = first
            if d == "comment" {
                model.commentDraft = "二つ目の問い（「先週から何が変わった？」）は来週のチームの 1on1 で試す。"
                model.commentTarget = first
            }
        }
        #endif
    }
}
