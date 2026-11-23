import SwiftUI

/// 回の詳細ページ（一覧の行をタップで push）。
/// アートワーク・題名・番組名（タップで番組の画面）・配信日・長さ・再生ボタン・キュー・ダウンロード・聴き終えた・概要（ショーノート）
struct EpisodeDetailView: View {
    @State private var store = PodcastStore.shared
    let episode: Episode
    @State private var notes: AttributedString?
    @State private var notesLoaded = false
    @State private var notesError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                playButton
                queueRow
                statusRow
                Divider()
                notesSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("エピソード")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let u = episode.url.flatMap(URL.init(string:)) {
                    ShareLink(item: u) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("共有")
                }
            }
        }
        .task(id: episode.id) { await loadNotes() }
        // 概要のリンクはアプリ内 Safari で（記事と同じ出し方）
        .environment(\.openURL, OpenURLAction { url in
            guard let s = url.scheme?.lowercased(), s == "http" || s == "https" else { return .systemAction }
            SafariPresenter.present(url: url) {}
            return .handled
        })
    }

    // MARK: - 上

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Button { PodcastRouter.shared.openShow(feedId: episode.feedId) } label: {
                    ArtworkView(url: episode.artworkURL, fallback: episode.feedTitle, size: 112)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("番組のアートワーク")
                .accessibilityIdentifier("episodeDetailArtwork")
                VStack(alignment: .leading, spacing: 8) {
                    Button { PodcastRouter.shared.openShow(feedId: episode.feedId) } label: {
                        HStack(spacing: 3) {
                            Text(episode.feedTitle).lineLimit(2).multilineTextAlignment(.leading)
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(episode.feedTitle)
                    .accessibilityIdentifier("episodeDetailShow")
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(episode.title)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("episodeDetailTitle")
        }
    }

    private var meta: String {
        var parts: [String] = []
        let date = When.fullDate(episode.publishedAt ?? episode.sortAt)
        if !date.isEmpty { parts.append(date) }
        if let d = episode.durationSec, d > 0 { parts.append(Duration.label(d)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 再生

    private var isCurrent: Bool { store.nowPlaying?.id == episode.id }

    /// 残り秒（途中まで聴いた回）。無ければ nil
    private var remaining: Int? {
        if isCurrent {
            let total = store.duration > 0 ? store.duration : Double(episode.durationSec ?? 0)
            return total > 0 ? Int(max(0, total - store.currentTime)) : nil
        }
        guard let pos = store.position(of: episode.id), pos > 1, let d = episode.durationSec, d > 0 else { return nil }
        return max(0, d - Int(pos))
    }

    private var playLabel: (title: String, icon: String) {
        if isCurrent && store.isPlaying { return ("一時停止", "pause.fill") }
        if let r = remaining, isCurrent || store.position(of: episode.id) != nil {
            return ("続きから · 残り\(Duration.label(r))", "play.fill")
        }
        if store.isPlayed(episode.id) { return ("もう一度再生", "arrow.counterclockwise") }
        return ("再生", "play.fill")
    }

    private var playButton: some View {
        Button {
            if isCurrent && store.isPlaying { store.pause() } else { store.play(episode) }
        } label: {
            HStack(spacing: 8) {
                if isCurrent && store.isBuffering {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: playLabel.icon)
                }
                Text(playLabel.title).font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("episodeDetailPlay")
        .accessibilityLabel(playLabel.title)
    }

    // MARK: - キュー

    private var queueRow: some View {
        HStack(spacing: 10) {
            if let loc = store.state.book.location(of: episode.id), let q = store.state.book.queue(loc.queue) {
                Label("\(q.name)の\(loc.index + 1)番目に入っています", systemImage: "text.badge.checkmark")
                    .font(.subheadline)
                    .foregroundStyle(Theme.readGreen)
                    .accessibilityIdentifier("episodeDetailQueueState")
                Spacer(minLength: 0)
                Button(role: .destructive) { store.remove(episode.id) } label: { Text("外す").font(.subheadline.weight(.semibold)) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("キューから外す")
            } else {
                Text("キューに入っていません").font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("episodeDetailQueueState")
                Spacer(minLength: 0)
            }
            Menu {
                ForEach(store.queues) { q in
                    Section(q.name) {
                        Button { store.add(episode, to: q.id, atTop: true) } label: {
                            Label("\(q.name)の先頭へ", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button { store.add(episode, to: q.id, atTop: false) } label: {
                            Label("\(q.name)の末尾へ", systemImage: "text.line.last.and.arrowtriangle.forward")
                        }
                    }
                }
            } label: {
                Label("キューへ", systemImage: "text.badge.plus").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("キューへ追加")
        }
    }

    // MARK: - ダウンロード・聴き終えた

    private var statusRow: some View {
        HStack(spacing: 10) {
            download
            Spacer(minLength: 0)
            Button {
                if store.isPlayed(episode.id) { store.markUnplayed(episode.id) } else { store.markPlayed(episode) }
            } label: {
                Label(store.isPlayed(episode.id) ? "未再生に戻す" : "聴き終えたにする",
                      systemImage: store.isPlayed(episode.id) ? "arrow.uturn.backward.circle" : "checkmark.circle")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("episodeDetailPlayedToggle")
        }
    }

    @ViewBuilder
    private var download: some View {
        Group {
            if store.isPlayed(episode.id) {
                Label("聴き終えました", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.readGreen)
            } else if store.isDownloaded(episode.id) {
                Label("ダウンロード済み", systemImage: "arrow.down.circle.fill").foregroundStyle(Theme.readGreen)
            } else if let p = store.progress[episode.id] {
                HStack(spacing: 6) {
                    ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini)
                    Text("ダウンロード中 \(Int(p * 100))%")
                }
                .foregroundStyle(.secondary)
            } else if let err = store.downloadErrors[episode.id] {
                Label("ダウンロードできません（\(err)）", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.error)
            } else if store.state.book.contains(episode.id) {
                Label(store.allowCellular ? "ダウンロード待ち" : "Wi-Fi でダウンロードします", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label("キューに入れるとダウンロード", systemImage: "icloud").foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .lineLimit(2)
        .accessibilityIdentifier("episodeDetailDownload")
    }

    // MARK: - 概要

    @ViewBuilder
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("概要").font(.headline)
            if let notes, !notes.characters.isEmpty {
                Text(notes)
                    .font(.callout)
                    .lineSpacing(4)
                    .tint(Theme.accent)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("episodeDetailNotes")
            } else if let notesError {
                Text(notesError).font(.footnote).foregroundStyle(Theme.error)
            } else if notesLoaded {
                Text("概要はありません").font(.footnote).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func loadNotes() async {
        do {
            let html = try await TayoriAPI.shared.episodeNotes(episode.id)
            notes = html.map(ShowNotes.attributed(fromHTML:))
            notesError = nil
        } catch {
            notesError = error.localizedDescription
        }
        notesLoaded = true
    }
}
