import SwiftUI

/// ポッドキャストのページの上のタブ: キュー（メイン・サブ…の順）→ 新着 → 番組
enum PodcastTab: Hashable {
    case queue(UUID)
    case new
    case shows
}

/// ポッドキャストのページ（下のタブバーの「ポッドキャスト」）
struct PodcastRootView: View {
    @State private var store = PodcastStore.shared
    @State private var tab: PodcastTab?
    @State private var nameEditor: QueueNameEditor?
    @State private var deletingQueue: PodcastQueue?
    @State private var showAdd = false
    @State private var path: [Podcast] = []
    @State private var demoApplied = false

    private var selected: PodcastTab {
        if let tab {
            if case let .queue(id) = tab, store.state.book.queue(id) == nil { return store.queues.first.map { .queue($0.id) } ?? .new }
            return tab
        }
        return store.queues.first.map { .queue($0.id) } ?? .new
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                tabBar
                Divider()
                content
            }
            .navigationTitle("ポッドキャスト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showAdd = true } label: { Label("番組を足す", systemImage: "plus.magnifyingglass") }
                        Button { nameEditor = QueueNameEditor(target: nil, name: "") } label: { Label("キューを作る", systemImage: "text.badge.plus") }
                        Toggle(isOn: Binding(get: { store.allowCellular }, set: { store.setAllowCellular($0) })) {
                            Label("モバイル通信でもダウンロード", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("番組を足す・キューを作る")
                }
            }
            .navigationDestination(for: Podcast.self) { p in ShowDetailView(podcast: p) }
        }
        .task {
            await store.refresh()
            applyDemo()
        }
        .sheet(item: $nameEditor) { e in
            QueueNameSheet(editor: e) { name in
                if let id = e.target {
                    store.renameQueue(id, to: name)
                } else if let id = store.createQueue(name) {
                    tab = .queue(id)
                }
            }
            .presentationDetents([.height(220)])
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack { AddPodcastView() }
                .presentationBackground(Color(uiColor: .systemBackground))
        }
        .confirmationDialog(
            "キュー「\(deletingQueue?.name ?? "")」を消しますか？",
            isPresented: Binding(get: { deletingQueue != nil }, set: { if !$0 { deletingQueue = nil } }),
            titleVisibility: .visible
        ) {
            Button("消す（中の回はキューから外れます）", role: .destructive) {
                if let q = deletingQueue { store.deleteQueue(q.id) }
                deletingQueue = nil
            }
        }
    }

    // MARK: - 上のタブ

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(store.queues) { q in
                        tabButton(q.name, count: q.episodes.count, .queue(q.id))
                            .contextMenu { queueMenu(q) }
                    }
                    tabButton("新着", count: 0, .new)
                    tabButton("番組", count: 0, .shows)
                }
                .padding(.horizontal, 6)
            }
            .onChange(of: selected) { _, t in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(t, anchor: .center) }
            }
        }
    }

    private func tabButton(_ name: String, count: Int, _ t: PodcastTab) -> some View {
        let on = selected == t
        return Button { tab = t } label: {
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(name).font(.footnote.weight(on ? .bold : .regular))
                    if count > 0 { Text("\(count)").font(.caption2) }
                }
                .foregroundStyle(on ? Theme.accent : Color.secondary)
                Rectangle().fill(on ? Theme.accent : .clear).frame(height: 2)
            }
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .frame(minHeight: 44, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "\(name), \(count)" : name)
        .accessibilityAddTraits(on ? .isSelected : [])
        .id(t)
    }

    @ViewBuilder
    private func queueMenu(_ q: PodcastQueue) -> some View {
        Button { nameEditor = QueueNameEditor(target: q.id, name: q.name) } label: { Label("名前を変える", systemImage: "pencil") }
        Button { store.moveQueue(q.id, by: -1) } label: { Label("左へ", systemImage: "arrow.left") }
            .disabled(store.queues.first?.id == q.id)
        Button { store.moveQueue(q.id, by: 1) } label: { Label("右へ", systemImage: "arrow.right") }
            .disabled(store.queues.last?.id == q.id)
        if store.queues.count > 1 {
            Button(role: .destructive) { deletingQueue = q } label: { Label("消す", systemImage: "trash") }
        }
    }

    // MARK: - 中身

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .queue(let id):
            if let q = store.state.book.queue(id) {
                QueueListView(queue: q, onRename: { nameEditor = QueueNameEditor(target: q.id, name: q.name) })
            }
        case .new:
            NewEpisodesView()
        case .shows:
            ShowsView(onAdd: { showAdd = true })
        }
    }

    /// DEBUG のスクリーンショット・UI テスト用
    ///   -tayoriPodcastDemo（seed の回でキューを作る）・-tayoriPodcastPlay（最初のキューの先頭を再生）・-tayoriPodcastTab new|shows|sub・-tayoriPodcastShow <番組名>・-tayoriPodcastAdd <検索語>
    private func applyDemo() {
        #if DEBUG
        guard !demoApplied else { return }
        demoApplied = true
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.index(after: i) < args.endIndex else { return nil }
            return args[args.index(after: i)]
        }
        if args.contains("-tayoriPodcastDemo") { store.applyDemoQueues() }
        // -tayoriPodcastPlay: 最初のキューの先頭を再生する（ミニプレーヤー・全画面プレーヤーの撮影用）
        if args.contains("-tayoriPodcastPlay"), let head = store.queues.first?.episodes.first { store.play(head) }
        switch value("-tayoriPodcastTab") {
        case "new": tab = .new
        case "shows": tab = .shows
        case "sub": if store.queues.count > 1 { tab = .queue(store.queues[1].id) }
        default: break
        }
        if let name = value("-tayoriPodcastShow"), let p = store.podcasts.first(where: { $0.title == name }) {
            tab = .shows
            path = [p]
        }
        if value("-tayoriPodcastAdd") != nil || value("-tayoriPodcastAddURL") != nil { showAdd = true }
        #endif
    }
}

// MARK: - キュー

struct QueueListView: View {
    @State private var store = PodcastStore.shared
    let queue: PodcastQueue
    var onRename: () -> Void = {}
    @State private var editMode: EditMode = .inactive
    @State private var moving: Episode?

    var body: some View {
        List {
            Section {
                ForEach(queue.episodes) { e in
                    EpisodeRow(episode: e, inQueue: queue.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { store.remove(e.id) } label: { Label("外す", systemImage: "minus.circle") }
                        }
                        .swipeActions(edge: .leading) {
                            if store.queues.count > 1 {
                                Button { moving = e } label: { Label("移す", systemImage: "arrow.right.arrow.left") }
                                    .tint(Theme.readGreen)
                            }
                        }
                }
                .onMove { from, to in store.move(in: queue.id, from: from, to: to) }
            } header: {
                header
            }
            if queue.episodes.isEmpty {
                VStack(spacing: 6) {
                    Text("「\(queue.name)」は空です").font(.subheadline).foregroundStyle(.secondary)
                    Text("新着や番組の回の ＋ から入れられます").font(.footnote).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowSeparator(.hidden)
            }
            if let e = store.errorMessage {
                Text(e).font(.footnote).foregroundStyle(Theme.error).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .refreshable { await store.refresh() }
        .confirmationDialog(
            "「\(moving?.title ?? "")」をどのキューへ移しますか？",
            isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }),
            titleVisibility: .visible
        ) {
            ForEach(store.queues.filter { $0.id != queue.id }) { q in
                Button("\(q.name)の先頭へ") { if let m = moving { store.add(m, to: q.id, atTop: true) }; moving = nil }
                Button("\(q.name)の末尾へ") { if let m = moving { store.add(m, to: q.id, atTop: false) }; moving = nil }
            }
        }
    }

    private var header: some View {
        HStack {
            let total = queue.episodes.reduce(0) { a, e in a + max(0, (e.durationSec ?? 0) - Int(store.position(of: e.id) ?? 0)) }
            Text(queue.episodes.isEmpty ? "" : "\(queue.episodes.count)回 · 残り \(Duration.label(total))")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if queue.episodes.count > 1 {
                Button(editMode == .active ? "終わる" : "並べ替え") {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                }
                .font(.caption.weight(.semibold))
            }
        }
        .textCase(nil)
    }
}

// MARK: - 新着

struct NewEpisodesView: View {
    @State private var store = PodcastStore.shared

    var body: some View {
        List {
            ForEach(store.newEpisodes) { e in
                EpisodeRow(episode: e, inQueue: nil)
                    .onAppear { if e.id == store.newEpisodes.last?.id { Task { await store.loadMoreNew() } } }
            }
            if store.newEpisodes.isEmpty && !store.isLoading {
                Text(store.podcasts.isEmpty ? "番組がありません。右上の ＋ から足せます" : "回はまだありません")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .listRowSeparator(.hidden)
            }
            if let e = store.errorMessage {
                Text(e).font(.footnote).foregroundStyle(Theme.error).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable { await store.refresh() }
    }
}

// MARK: - 1回の行

/// 1回: アートワーク／題名（2行）／番組 · 日付 · 長さ（途中なら残り）／ダウンロードとキューの印。
/// タップで再生、右の ＋ でキューの先頭／末尾へ（長押しでも同じメニュー）
struct EpisodeRow: View {
    @State private var store = PodcastStore.shared
    let episode: Episode
    /// キューの中の行ならそのキュー（「外す」をメニューに出す）
    let inQueue: UUID?
    var showArtwork = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showArtwork {
                ArtworkView(url: episode.artworkURL, fallback: episode.feedTitle, size: 52)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCurrent ? Theme.accent : Color.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    statusIcon
                }
            }
            Spacer(minLength: 0)
            AddToQueueMenu(episode: episode, inQueue: inQueue) {
                Image(systemName: store.state.book.contains(episode.id) ? "text.badge.checkmark" : "text.badge.plus")
                    .font(.body)
                    .foregroundStyle(store.state.book.contains(episode.id) ? Theme.readGreen : Theme.accent)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("キューに入れる")
        }
        .contentShape(Rectangle())
        .onTapGesture { store.play(episode) }
        .contextMenu {
            QueueMenuItems(episode: episode, store: store)
        }
        .accessibilityElement(children: .contain)
    }

    private var isCurrent: Bool { store.nowPlaying?.id == episode.id }

    private var meta: String {
        var parts: [String] = []
        if inQueue != nil || showArtwork { parts.append(episode.feedTitle) }
        parts.append(When.relative(episode.publishedAt ?? episode.sortAt))
        if let pos = store.position(of: episode.id), pos > 1, let d = episode.durationSec, d > 0 {
            parts.append("残り\(Duration.label(max(0, d - Int(pos))))")
        } else if let d = episode.durationSec {
            parts.append(Duration.label(d))
        }
        if inQueue == nil, let q = store.queueName(of: episode.id) { parts.append(q) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isCurrent && store.isPlaying {
            Image(systemName: "waveform").font(.caption2).foregroundStyle(Theme.accent)
        }
        if store.isDownloaded(episode.id) {
            Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(Theme.readGreen)
                .accessibilityLabel("ダウンロード済み")
        } else if let p = store.progress[episode.id] {
            ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini)
                .accessibilityLabel("ダウンロード中")
        }
    }
}

/// キューに入れるメニュー（どのキューの先頭／末尾へ・外す）
struct AddToQueueMenu<Label: View>: View {
    @State private var store = PodcastStore.shared
    let episode: Episode
    let inQueue: UUID?
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            QueueMenuItems(episode: episode, store: store)
        } label: {
            label()
        }
    }
}

/// キューのメニューの中身（行の ＋ と長押しで共通）
struct QueueMenuItems: View {
    let episode: Episode
    let store: PodcastStore

    var body: some View {
        Button { store.play(episode) } label: { SwiftUI.Label("再生", systemImage: "play.fill") }
        ForEach(store.queues) { q in
            Section(q.name) {
                Button { store.add(episode, to: q.id, atTop: true) } label: {
                    SwiftUI.Label("\(q.name)の先頭へ", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { store.add(episode, to: q.id, atTop: false) } label: {
                    SwiftUI.Label("\(q.name)の末尾へ", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
        }
        if store.state.book.contains(episode.id) {
            Button(role: .destructive) { store.remove(episode.id) } label: {
                SwiftUI.Label("キューから外す", systemImage: "minus.circle")
            }
        }
        if let u = episode.url.flatMap(URL.init(string:)) {
            ShareLink(item: u) { SwiftUI.Label("共有", systemImage: "square.and.arrow.up") }
        }
    }
}

/// 番組のアートワーク（取れなければ頭文字）
struct ArtworkView: View {
    let url: URL?
    let fallback: String
    var size: CGFloat = 52

    var body: some View {
        FaviconView(url: url, fallback: String(fallback.trimmingCharacters(in: .whitespaces).first ?? "・"), size: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.16))
    }
}

// MARK: - キューの名前

struct QueueNameEditor: Identifiable {
    let id = UUID()
    /// nil = 新しく作る
    let target: UUID?
    var name: String
}

struct QueueNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let editor: QueueNameEditor
    let onSave: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editor.target == nil ? "キューを作る" : "キューの名前を変える").font(.headline)
            IMESafeTextField(text: $name, placeholder: "例: 通勤・寝る前", returnKey: .done, autocapitalization: .none) { save() }
                .frame(height: 40)
                .padding(.horizontal, 10)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("やめる") { dismiss() }
                Spacer()
                Button("保存") { save() }
                    .bold()
                    .disabled(QueueBook.normalize(name) == nil)
            }
        }
        .padding(20)
        .onAppear { name = editor.name }
    }

    private func save() {
        guard QueueBook.normalize(name) != nil else { return }
        onSave(name)
        dismiss()
    }
}
