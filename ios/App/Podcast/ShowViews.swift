import SwiftUI

// MARK: - 番組の一覧

struct ShowsView: View {
    @State private var store = PodcastStore.shared
    var onAdd: () -> Void
    @State private var removing: Podcast?

    var body: some View {
        List {
            Button(action: onAdd) {
                Label("番組を足す（名前で探す・フィードの URL）", systemImage: "plus.magnifyingglass")
                    .font(.subheadline)
            }
            ForEach(store.podcasts) { p in
                NavigationLink(value: p) {
                    HStack(spacing: 12) {
                        ArtworkView(url: p.artworkURL, fallback: p.title, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(meta(p)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if p.lastError != nil {
                                Label("取得できません", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(Theme.error)
                            }
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { removing = p } label: { Label("外す", systemImage: "trash") }
                }
            }
            if store.podcasts.isEmpty && !store.isLoading {
                Text("番組がありません").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 40).listRowSeparator(.hidden)
            }
            if let e = store.errorMessage {
                Text(e).font(.footnote).foregroundStyle(Theme.error).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable { await store.refresh() }
        .confirmationDialog(
            "「\(removing?.title ?? "")」を外しますか？",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("外す（回の一覧も消えます）", role: .destructive) {
                if let p = removing { Task { await store.deletePodcast(p) } }
                removing = nil
            }
        }
    }

    private func meta(_ p: Podcast) -> String {
        var parts = ["\(p.episodes)回"]
        if let l = p.latestAt { parts.append("最新 \(When.relative(l))") }
        parts.append(AutoAddLabel.text(store.autoAdd(for: p.id), store: store))
        return parts.joined(separator: " · ")
    }
}

enum AutoAddLabel {
    @MainActor
    static func text(_ a: AutoAdd, store: PodcastStore) -> String {
        switch a {
        case .off: return "自動で入れない"
        case let .queue(id, top):
            let name = store.state.book.queue(id)?.name ?? "?"
            return "\(name)の\(top ? "先頭" : "末尾")へ自動"
        }
    }
}

// MARK: - 番組のエピソード一覧

struct ShowDetailView: View {
    @State private var store = PodcastStore.shared
    let podcast: Podcast
    @State private var episodes: [Episode] = []
    @State private var next: String?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                header.listRowSeparator(.hidden)
            }
            Section {
                ForEach(episodes) { e in
                    EpisodeRow(episode: e, inQueue: nil, showArtwork: false)
                        .onAppear { if e.id == episodes.last?.id { Task { await loadMore() } } }
                }
                if episodes.isEmpty && !loading {
                    Text("回はまだありません（取得を待っています）").font(.footnote).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.error)
                }
            } header: {
                Text("エピソード \(podcast.episodes)").font(.caption).textCase(nil)
            }
        }
        .listStyle(.plain)
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable {
            _ = try? await TayoriAPI.shared.refreshFeed(podcast.id)
            await reload()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ArtworkView(url: podcast.artworkURL, fallback: podcast.title, size: 96)
            VStack(alignment: .leading, spacing: 8) {
                Text(podcast.title).font(.headline).lineLimit(3)
                Menu {
                    Picker("自動追加", selection: Binding(get: { store.autoAdd(for: podcast.id) }, set: { store.setAutoAdd($0, for: podcast.id) })) {
                        Text("自動で入れない").tag(AutoAdd.off)
                        ForEach(store.queues) { q in
                            Text("\(q.name)の先頭へ").tag(AutoAdd.queue(q.id, atTop: true))
                            Text("\(q.name)の末尾へ").tag(AutoAdd.queue(q.id, atTop: false))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.badge.plus")
                        Text("新着: " + AutoAddLabel.text(store.autoAdd(for: podcast.id), store: store))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.chip, in: Capsule())
                }
                .accessibilityLabel("新着の自動追加")
                if let e = podcast.lastError {
                    Label("取得できません（\(e)）", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(Theme.error)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let p = try await TayoriAPI.shared.episodes(podcast: podcast.id)
            episodes = p.episodes
            next = p.next
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let cursor = next, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let p = try await TayoriAPI.shared.episodes(podcast: podcast.id, before: cursor)
            let known = Set(episodes.map(\.id))
            episodes += p.episodes.filter { !known.contains($0.id) }
            next = p.next
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 番組を足す（名前で探す・フィードの URL）

struct AddPodcastView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = PodcastStore.shared
    @State private var term = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var searching = false
    @State private var url = ""
    @State private var adding: String?
    @State private var message: String?
    @State private var failure: String?
    @State private var searched = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    IMESafeTextField(text: $term, placeholder: "番組の名前で探す", returnKey: .search, autocapitalization: .none) {
                        Task { await search() }
                    }
                    .frame(height: 36)
                    if searching { ProgressView() }
                }
                ForEach(results) { r in
                    HStack(spacing: 12) {
                        ArtworkView(url: r.artworkURL, fallback: r.collectionName, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.collectionName).font(.subheadline.weight(.semibold)).lineLimit(2)
                            if let a = r.artistName { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                        addButton(feedUrl: r.feedUrl)
                    }
                }
                if searched && results.isEmpty && !searching {
                    Text("見つかりませんでした").font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("名前で探す（Apple Podcasts の目録）").textCase(nil)
            }
            Section {
                IMESafeTextField(text: $url, placeholder: "https://…/feed.xml", keyboard: .URL, returnKey: .go, autocapitalization: .none) {
                    Task { await add(url) }
                }
                .frame(height: 36)
                Button {
                    Task { await add(url) }
                } label: {
                    Text(adding == url && !url.isEmpty ? "追加しています…" : "フィードの URL で足す")
                }
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || adding != nil)
            } header: {
                Text("フィードの URL").textCase(nil)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(Theme.readGreen)
            }
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(Theme.error)
            }
        }
        .navigationTitle("番組を足す")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } }
        }
        .task {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-tayoriPodcastAdd"), args.index(after: i) < args.endIndex, term.isEmpty {
                term = args[args.index(after: i)]
                await search()
            }
            // -tayoriPodcastAddURL <URL>: フィードの URL 欄に下書きを入れる（送るのはボタン）
            if let i = args.firstIndex(of: "-tayoriPodcastAddURL"), args.index(after: i) < args.endIndex, url.isEmpty {
                url = args[args.index(after: i)]
            }
            #endif
        }
    }

    private func isSubscribed(_ feedUrl: String?) -> Bool {
        guard let f = feedUrl else { return false }
        return store.podcasts.contains { $0.feedUrl == f }
    }

    @ViewBuilder
    private func addButton(feedUrl: String?) -> some View {
        if isSubscribed(feedUrl) {
            Text("追加済み").font(.caption).foregroundStyle(.secondary)
        } else if let f = feedUrl {
            Button {
                Task { await add(f) }
            } label: {
                if adding == f { ProgressView() } else { Text("追加").font(.caption.weight(.semibold)) }
            }
            .buttonStyle(.bordered)
            .disabled(adding != nil)
        }
    }

    private func search() async {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await TayoriAPI.shared.searchPodcasts(t)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        searched = true
    }

    private func add(_ raw: String) async {
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        adding = u
        defer { adding = nil }
        message = nil
        failure = nil
        switch await store.addPodcast(url: u) {
        case .success(let r):
            let p = r.podcast
            if r.created {
                message = "足しました（\(p.title)・\(p.episodes)回）"
            } else if r.converted == true {
                message = "記事から番組へ移しました（\(p.title)・\(p.episodes)回）"
            } else {
                message = "もう入っています（\(p.title)）"
            }
            if u == url { url = "" }
        case .failure(let e):
            failure = e.localizedDescription
        }
    }
}
