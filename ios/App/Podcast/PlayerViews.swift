import SwiftUI

/// 画面の下（タブバーの上）に常に出る小さなプレーヤー。押すと全画面
struct MiniPlayer: View {
    @State private var store = PodcastStore.shared
    var onOpen: () -> Void

    var body: some View {
        if let ep = store.nowPlaying {
            HStack(spacing: 10) {
                ArtworkView(url: ep.artworkURL, fallback: ep.feedTitle, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ep.title).font(.footnote.weight(.semibold)).lineLimit(1)
                        .accessibilityIdentifier("nowPlayingTitle")
                    Text(remaining).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { store.togglePlay() } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(store.isPlaying ? "一時停止" : "再生")
                Button { store.skip(by: PodcastStore.skipForward) } label: {
                    Image(systemName: "goforward.30")
                        .font(.body)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("30秒送る")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("miniPlayer")
        } else {
            HStack {
                Image(systemName: "headphones").foregroundStyle(.secondary)
                Text("再生中の回はありません").font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
        }
    }

    private var remaining: String {
        let ep = store.nowPlaying
        let total = store.duration > 0 ? store.duration : Double(ep?.durationSec ?? 0)
        let left = max(0, total - store.currentTime)
        return "\(ep?.feedTitle ?? "") · 残り \(Duration.clock(left))"
    }
}

/// 全画面のプレーヤー: アートワーク・シーク・15秒戻し／30秒送り・速度・次に聴く回
struct FullPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = PodcastStore.shared
    @State private var scrubbing: Double?
    @State private var showSpeed = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("閉じる")
                Spacer()
                if let ep = store.nowPlaying, let q = store.queueName(of: ep.id) {
                    Text(q).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.chip, in: Capsule())
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            if let ep = store.nowPlaying {
                ArtworkView(url: ep.artworkURL, fallback: ep.feedTitle, size: 280)
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                VStack(spacing: 6) {
                    Text(ep.title).font(.headline).multilineTextAlignment(.center).lineLimit(3)
                    HStack(spacing: 6) {
                        Text(ep.feedTitle).font(.subheadline).foregroundStyle(.secondary)
                        if store.isDownloaded(ep.id) {
                            Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(Theme.readGreen)
                                .accessibilityLabel("ダウンロード済み")
                        }
                    }
                }
                .padding(.horizontal, 24)
                scrubber
                controls
                speedRow
                upNext
            } else {
                Spacer()
                Text("再生中の回はありません").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .background(Color(uiColor: .systemBackground))
    }

    private var total: Double {
        store.duration > 0 ? store.duration : Double(store.nowPlaying?.durationSec ?? 0)
    }

    private var scrubber: some View {
        let t = scrubbing ?? store.currentTime
        return VStack(spacing: 4) {
            Slider(
                value: Binding(get: { min(t, max(total, 1)) }, set: { scrubbing = $0 }),
                in: 0...max(total, 1),
                onEditingChanged: { editing in
                    if !editing, let s = scrubbing {
                        store.seek(to: s)
                        scrubbing = nil
                    }
                }
            )
            .accessibilityLabel("再生位置")
            HStack {
                Text(Duration.clock(t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text("-" + Duration.clock(max(0, total - t))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 44) {
            Button { store.skip(by: -PodcastStore.skipBack) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 30))
            }
            .accessibilityLabel("15秒戻す")
            Button { store.togglePlay() } label: {
                ZStack {
                    Circle().fill(Theme.accent).frame(width: 72, height: 72)
                    if store.isBuffering {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30)).foregroundStyle(.white)
                            .offset(x: store.isPlaying ? 0 : 2)
                    }
                }
            }
            .accessibilityLabel(store.isPlaying ? "一時停止" : "再生")
            Button { store.skip(by: PodcastStore.skipForward) } label: {
                Image(systemName: "goforward.30").font(.system(size: 30))
            }
            .accessibilityLabel("30秒送る")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    /// 速度: −／＋ で 0.1 ずつ・数字を押すとよく使う値の一覧
    private var speedRow: some View {
        HStack(spacing: 14) {
            Button { store.setSpeed(store.speed - 0.1) } label: {
                Image(systemName: "minus").frame(width: 36, height: 32)
            }
            .disabled(store.speed <= PodcastStore.speedRange.lowerBound + 0.001)
            .accessibilityLabel("遅くする")
            Menu {
                ForEach([0.8, 1.0, 1.2, 1.3, 1.5, 1.7, 2.0, 2.5, 3.0], id: \.self) { v in
                    Button(String(format: "%.1f×", v)) { store.setSpeed(v) }
                }
            } label: {
                Text(String(format: "%.1f×", store.speed))
                    .font(.headline.monospacedDigit())
                    .frame(minWidth: 64)
                    .padding(.vertical, 6)
                    .background(Theme.chip, in: Capsule())
            }
            .accessibilityLabel("再生速度")
            .accessibilityValue(String(format: "%.1f倍", store.speed))
            Button { store.setSpeed(store.speed + 0.1) } label: {
                Image(systemName: "plus").frame(width: 36, height: 32)
            }
            .disabled(store.speed >= PodcastStore.speedRange.upperBound - 0.001)
            .accessibilityLabel("速くする")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    /// 次に聴く回（聴き終えたら進む先: 同じキューの先頭 → 右隣のキュー）
    @ViewBuilder
    private var upNext: some View {
        if let ep = store.nowPlaying {
            var book = store.state.book
            let next = book.finish(ep.id, playingFrom: store.state.playingQueue)
            if let next {
                HStack(spacing: 8) {
                    Text("次").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(next.episode.title).font(.caption).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(book.queue(next.queue)?.name ?? "").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text("このあとは止まります（キューの最後）").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
