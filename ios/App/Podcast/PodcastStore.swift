import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

/// 端末の中に持つポッドキャストの状態（Worker と同期しない）。Application Support/podcast-state.json に保存する
struct PodcastState: Codable, Equatable {
    var book: QueueBook = .initial()
    /// 続きから再開する位置（秒）。聴き終えたら消す
    var positions: [Int: Double] = [:]
    /// 番組ごとの自動追加（無ければ「入れない」）
    var autoAdd: [Int: AutoAdd] = [:]
    /// 番組ごとに「ここまでの回は見た」id（新着の自動追加の目印）
    var watermarks: [Int: Int] = [:]
    /// 再生速度（全体で1つ・0.5〜3.0・0.1 刻み）
    var speed: Double = 1.0
    /// モバイル通信でもダウンロードする（既定は Wi-Fi のときだけ）
    var allowCellular = false
    /// 再生中（一時停止中を含む）の回と、そのとき再生していたキュー
    var nowPlaying: Episode?
    var playingQueue: UUID?
    /// 聴き終えた回（id → 聴き終えた時刻）。最後まで再生した・残り30秒未満で次へ移った・手で「聴き終えた」にした回（2026-11-24 から）
    var played: [Int: Date] = [:]

    init() {}

    /// 鍵が足りなくても読む（played の無い 2026-11-24 より前の保存データを、キューや位置を失わずに読むため）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PodcastState()
        book = try c.decodeIfPresent(QueueBook.self, forKey: .book) ?? d.book
        positions = try c.decodeIfPresent([Int: Double].self, forKey: .positions) ?? [:]
        autoAdd = try c.decodeIfPresent([Int: AutoAdd].self, forKey: .autoAdd) ?? [:]
        watermarks = try c.decodeIfPresent([Int: Int].self, forKey: .watermarks) ?? [:]
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        allowCellular = try c.decodeIfPresent(Bool.self, forKey: .allowCellular) ?? false
        nowPlaying = try c.decodeIfPresent(Episode.self, forKey: .nowPlaying)
        playingQueue = try c.decodeIfPresent(UUID.self, forKey: .playingQueue)
        played = try c.decodeIfPresent([Int: Date].self, forKey: .played) ?? [:]
    }
}

/// ポッドキャストのページと再生の中心: キュー・番組の設定・新着の取り込み・ダウンロード・AVPlayer・ロック画面
@MainActor
@Observable
final class PodcastStore {
    static let shared = PodcastStore()

    // 端末に保存するもの
    private(set) var state = PodcastState()

    // Worker から読むもの
    var podcasts: [Podcast] = []
    var newEpisodes: [Episode] = []
    var newNext: String?
    private var isLoadingMoreNew = false
    var errorMessage: String?
    var isLoading = false

    // ダウンロード
    private(set) var downloaded: Set<Int> = []
    private(set) var progress: [Int: Double] = [:]
    private(set) var downloadErrors: [Int: String] = [:]

    // 再生
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    /// 聴き終え＝残りがこの秒数を切ったとき
    static let finishThreshold: Double = 30
    static let speedRange: ClosedRange<Double> = 0.5...3.0
    static let skipBack: Double = 15
    static let skipForward: Double = 30
    /// 新着の自動追加は、この日数より新しい回だけ（過去回が後から入ったときに溢れないように）
    static let autoAddWindow: TimeInterval = 7 * 86400

    private let api = TayoriAPI.shared
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var readyObservation: NSKeyValueObservation?
    private var lastSavedAt = Date.distantPast
    private var configured = false
    /// DEBUG の UI テスト用: 回を読み込むたびに末尾の N 秒前へ飛ぶ（キューの連鎖を短い時間で確かめる）
    private var debugSeekNearEnd: Double?

    private init() {}

    // MARK: - 起動

    /// アプリの起動で一度だけ: 保存した状態を読み、プレーヤーとダウンロードの口をつなぐ
    func configure() {
        guard !configured else { return }
        configured = true
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-tayoriPodcastReset") {
            try? FileManager.default.removeItem(at: Self.stateURL)
            EpisodeDownloader.deleteAll()
        }
        if let i = args.firstIndex(of: "-tayoriSeekNearEnd"), args.index(after: i) < args.endIndex {
            debugSeekNearEnd = Double(args[args.index(after: i)])
        }
        #endif
        state = Self.load()
        downloaded = EpisodeDownloader.downloadedIds()
        player.automaticallyWaitsToMinimizeStalling = true
        setupDownloader()
        setupPlayerObservers()
        setupRemoteCommands()
        if let ep = state.nowPlaying {
            // 前回の続き（再生はしない・ミニプレーヤーに出す）
            load(ep, autoplay: false)
        }
        Task { await reconcileDownloads() }
    }

    // MARK: - 保存

    private static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("podcast-state.json")
    }

    private static func load() -> PodcastState {
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(PodcastState.self, from: data) else { return PodcastState() }
        return s
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }

    private func mutate(_ f: (inout PodcastState) -> Void) {
        f(&state)
        save()
    }

    // MARK: - キュー

    var queues: [PodcastQueue] { state.book.queues }
    var speed: Double { state.speed }
    var allowCellular: Bool { state.allowCellular }
    var nowPlaying: Episode? { state.nowPlaying }

    func queueName(of episodeId: Int) -> String? {
        state.book.location(of: episodeId).flatMap { state.book.queue($0.queue)?.name }
    }

    func add(_ episode: Episode, to queueId: UUID, atTop: Bool) {
        mutate { $0.book.add(episode, to: queueId, atTop: atTop) }
        if state.nowPlaying?.id == episode.id { mutate { $0.playingQueue = queueId } }
        Task { await reconcileDownloads() }
    }

    func remove(_ episodeId: Int) {
        mutate { $0.book.remove(episodeId) }
        Task { await reconcileDownloads() }
    }

    func move(in queueId: UUID, from: IndexSet, to: Int) {
        mutate { $0.book.move(in: queueId, from: from, to: to) }
    }

    /// 取っ手でドラッグして並べ替えた後の並び
    func reorder(in queueId: UUID, to ids: [Int]) {
        mutate { $0.book.reorder(in: queueId, to: ids) }
    }

    @discardableResult
    func createQueue(_ name: String) -> UUID? {
        var id: UUID?
        mutate { id = $0.book.createQueue(name: name) }
        return id
    }

    func renameQueue(_ id: UUID, to name: String) { mutate { $0.book.rename(id, to: name) } }
    func moveQueue(_ id: UUID, by delta: Int) { mutate { $0.book.moveQueue(id, by: delta) } }

    func deleteQueue(_ id: UUID) {
        mutate { s in
            s.book.deleteQueue(id)
            // その キューへの自動追加は「入れない」に戻す
            for (feed, a) in s.autoAdd { if case .queue(id) = a { s.autoAdd[feed] = .off } }
            if s.playingQueue == id { s.playingQueue = nil }
        }
        Task { await reconcileDownloads() }
    }

    // MARK: - 番組の設定

    func autoAdd(for feedId: Int) -> AutoAdd {
        let a = state.autoAdd[feedId] ?? .off
        if case let .queue(q) = a, state.book.queue(q) == nil { return .off }
        return a
    }

    func setAutoAdd(_ a: AutoAdd, for feedId: Int) { mutate { $0.autoAdd[feedId] = a } }

    func setSpeed(_ v: Double) {
        let r = (min(max(v, Self.speedRange.lowerBound), Self.speedRange.upperBound) * 10).rounded() / 10
        mutate { $0.speed = r }
        player.defaultRate = Float(r)
        if isPlaying { player.rate = Float(r) }
        updateNowPlayingInfo()
    }

    func setAllowCellular(_ on: Bool) {
        mutate { $0.allowCellular = on }
        // 待っている転送は今の設定で取り直す
        Task {
            await EpisodeDownloader.shared.cancelAll()
            progress = [:]
            await reconcileDownloads()
        }
    }

    // MARK: - Worker から読む・新着の自動追加

    /// 番組と新着を読み、番組の設定に従って新着をキューへ入れる
    func refresh() async {
        guard TayoriAPI.shared.isConfigured else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let pods = api.podcasts()
            async let page = api.episodes(limit: EpisodePaging.pageSize)
            let (p, n) = try await (pods, page)
            podcasts = p
            newEpisodes = n.episodes
            newNext = n.next
            errorMessage = nil
            await applyAutoAdd(p)
        } catch {
            errorMessage = error.localizedDescription
        }
        await reconcileDownloads()
    }

    func loadMoreNew() async {
        guard let cursor = newNext, !isLoadingMoreNew else { return }
        isLoadingMoreNew = true
        defer { isLoadingMoreNew = false }
        do {
            let p = try await api.episodes(before: cursor, limit: EpisodePaging.pageSize)
            let known = Set(newEpisodes.map(\.id))
            newEpisodes += p.episodes.filter { !known.contains($0.id) }
            newNext = p.next
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 番組ごとに「見た」id より後の回を取り、設定（入れない／キューの先頭・末尾）に従って入れる。
    /// 初めて見る番組は今ある回を「見た」にするだけ（足した直後に過去回がキューへ溢れないように）
    private func applyAutoAdd(_ pods: [Podcast]) async {
        let since = Date().addingTimeInterval(-Self.autoAddWindow)
        for p in pods {
            guard let latest = p.latestEpisodeId else { continue }
            guard let mark = state.watermarks[p.id] else {
                mutate { $0.watermarks[p.id] = latest }
                continue
            }
            guard latest > mark else { continue }
            let setting = autoAdd(for: p.id)
            if setting != .off {
                var fresh: [Episode] = []
                var after = mark
                do {
                    while true {
                        let page = try await api.episodes(podcast: p.id, afterId: after, limit: 100)
                        fresh += page.episodes
                        guard let n = page.next, let nid = Int(n) else { break }
                        after = nid
                    }
                } catch {
                    errorMessage = error.localizedDescription
                    continue // 目印は進めない（次に読み直す）
                }
                let skip = Set(state.played.keys)
                mutate { $0.book.autoAdd(fresh, setting: setting, since: since, skipping: skip) }
            }
            mutate { $0.watermarks[p.id] = latest }
        }
    }

    func addPodcast(url: String) async -> Result<AddPodcastResult, Error> {
        do {
            let r = try await api.addPodcast(url: url)
            await refresh()
            return .success(r)
        } catch {
            return .failure(error)
        }
    }

    func deletePodcast(_ p: Podcast) async {
        do {
            try await api.deletePodcast(p.id)
            mutate { s in
                s.autoAdd[p.id] = nil
                s.watermarks[p.id] = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    // MARK: - ダウンロード

    private func setupDownloader() {
        let d = EpisodeDownloader.shared
        d.onFinished = { [weak self] id in
            guard let self else { return }
            self.progress[id] = nil
            self.downloadErrors[id] = nil
            self.downloaded.insert(id)
            // もう要らなくなっていたら消す
            if !self.wanted.contains(id) { EpisodeDownloader.deleteFile(for: id); self.downloaded.remove(id) }
        }
        d.onFailed = { [weak self] id, msg in
            self?.progress[id] = nil
            self?.downloadErrors[id] = msg
        }
        // 止めた転送の遅れて届いた知らせで「転送中」に戻さない（要る回だけ）
        d.onProgress = { [weak self] id, p in
            guard let self, self.wanted.contains(id), !self.downloaded.contains(id) else { return }
            self.progress[id] = p
        }
        // 強制終了などでシステムが止めた転送: まだ要る回なら取り直す（少し待って、照合をまとめて1回）
        d.onInterrupted = { [weak self] id in
            guard let self else { return }
            self.progress[id] = nil
            guard self.wanted.contains(id) else { return }
            Task {
                try? await Task.sleep(for: .seconds(1))
                await self.reconcileDownloads()
            }
        }
        d.activate()
    }

    /// 端末に置いておく回 = どこかのキューにある回＋再生中の回
    private var wanted: Set<Int> {
        var s = Set(state.book.allEpisodes.map(\.id))
        if let n = state.nowPlaying { s.insert(n.id) }
        return s
    }

    /// キューに入った回を落とし、要らなくなった回（聴き終えた・外した）のファイルと転送を消す
    func reconcileDownloads() async {
        let want = wanted
        let active = await EpisodeDownloader.shared.activeTasks()
        downloadLog.info("reconcile want=\(want.sorted(), privacy: .public) active=\(active.keys.sorted(), privacy: .public) progress=\(self.progress.keys.sorted(), privacy: .public)")
        for (id, task) in active where !want.contains(id) {
            EpisodeDownloader.shared.cancel(task)
            progress[id] = nil
        }
        for id in EpisodeDownloader.downloadedIds() where !want.contains(id) {
            // 再生中のファイルは消さない
            if state.nowPlaying?.id == id { continue }
            EpisodeDownloader.deleteFile(for: id)
        }
        downloaded = EpisodeDownloader.downloadedIds()
        // 「転送中」は実際に走っている転送だけで決める（前回の起動の残りや止めた転送の進み具合は捨てる）
        for id in progress.keys where active[id] == nil || !want.contains(id) { progress[id] = nil }
        let episodes = state.book.allEpisodes + (state.nowPlaying.map { [$0] } ?? [])
        var seen = Set<Int>()
        for e in episodes where seen.insert(e.id).inserted && !downloaded.contains(e.id) && active[e.id] == nil {
            downloadErrors[e.id] = nil
            progress[e.id] = 0
            EpisodeDownloader.shared.start(e, allowCellular: state.allowCellular)
        }
    }

    func isDownloaded(_ id: Int) -> Bool { downloaded.contains(id) }

    // MARK: - 再生

    /// この回を再生する（キューから・一覧から）。別の回を聴いている途中で、残り30秒を切っていたらその回は聴き終え扱い
    func play(_ episode: Episode) {
        if let cur = state.nowPlaying, cur.id != episode.id {
            savePosition()
            if duration > 0, duration - currentTime < Self.finishThreshold {
                finishCurrent(advance: false)
            }
        }
        if state.nowPlaying?.id == episode.id, player.currentItem != nil {
            resume()
            return
        }
        let q = state.book.location(of: episode.id)?.queue
        mutate {
            $0.nowPlaying = episode
            $0.playingQueue = q
            // 聴き終えた回をもう一度聴く: 「途中」に戻る（頭から）
            if $0.played.removeValue(forKey: episode.id) != nil { $0.positions[episode.id] = nil }
        }
        load(episode, autoplay: true)
        Task { await reconcileDownloads() }
    }

    private func load(_ episode: Episode, autoplay: Bool) {
        let local = EpisodeDownloader.localFile(for: episode.id)
        guard let url = local ?? episode.audioURL else { return }
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        player.defaultRate = Float(state.speed)
        let known = Double(episode.durationSec ?? 0)
        let saved = state.positions[episode.id] ?? 0
        // 続きから（残り30秒を切った位置なら頭から）
        let start: Double? = saved > 1 && (known == 0 || known - saved >= Self.finishThreshold) ? saved : nil
        currentTime = start ?? 0
        duration = known
        observeEnd(of: item)
        // seek は読み込みが済んでから（済む前の completion つき seek は例外で落ちる）
        readyObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] it, _ in
            guard it.status == .readyToPlay else { return }
            Task { @MainActor in self?.itemReady(it, start: start, autoplay: autoplay) }
        }
        if autoplay && start == nil && debugSeekNearEnd == nil { resume() }
        updateNowPlayingInfo()
        loadArtwork(for: episode)
    }

    /// 読み込みが済んだ: 続きの位置へ飛んでから再生（DEBUG の UI テストでは末尾の N 秒前へ）
    private func itemReady(_ item: AVPlayerItem, start: Double?, autoplay: Bool) {
        guard player.currentItem === item else { return }
        readyObservation = nil
        var target = start
        if let n = debugSeekNearEnd {
            let d = item.duration.seconds
            let total = d.isFinite && d > 0 ? d : duration
            if total > n { target = total - n }
        }
        guard let target else { return }
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if autoplay { self.resume() }
                self.updateNowPlayingInfo()
            }
        }
    }

    func resume() {
        guard player.currentItem != nil else {
            if let ep = state.nowPlaying { load(ep, autoplay: true) }
            return
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try? session.setActive(true)
        player.playImmediately(atRate: Float(state.speed))
        updateNowPlayingInfo()
    }

    func pause() {
        player.pause()
        savePosition()
        updateNowPlayingInfo()
    }

    func togglePlay() { isPlaying ? pause() : resume() }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func seek(to seconds: Double) {
        let d = duration > 0 ? duration : .greatestFiniteMagnitude
        let t = max(0, min(seconds, d - 0.5))
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.savePosition()
                self?.updateNowPlayingInfo()
            }
        }
    }

    private func savePosition() {
        guard let ep = state.nowPlaying else { return }
        let t = player.currentTime().seconds
        guard t.isFinite else { return }
        mutate { $0.positions[ep.id] = t }
        lastSavedAt = Date()
    }

    /// 聴き終えた: キューから外し、位置とファイルを消す。advance なら次の回（同じキューの先頭 → 右隣のキュー）を再生する
    private func finishCurrent(advance: Bool) {
        guard let ep = state.nowPlaying else { return }
        var next: (episode: Episode, queue: UUID)?
        mutate { s in
            next = s.book.finish(ep.id, playingFrom: s.playingQueue)
            s.positions[ep.id] = nil
            s.played[ep.id] = Date()
            s.nowPlaying = nil
            s.playingQueue = nil
        }
        EpisodeDownloader.deleteFile(for: ep.id)
        downloaded.remove(ep.id)
        if advance, let next {
            mutate {
                $0.nowPlaying = next.episode
                $0.playingQueue = next.queue
            }
            load(next.episode, autoplay: true)
        } else if advance {
            // 最後のキューまで聴き終えた: 止まる
            player.replaceCurrentItem(with: nil)
            currentTime = 0
            duration = 0
            updateNowPlayingInfo()
        }
        Task { await reconcileDownloads() }
    }

    /// プレーヤーを閉じる（再生中の回を外す。キューには残る）
    func stop() {
        savePosition()
        player.pause()
        player.replaceCurrentItem(with: nil)
        mutate {
            $0.nowPlaying = nil
            $0.playingQueue = nil
        }
        currentTime = 0
        duration = 0
        updateNowPlayingInfo()
        Task { await reconcileDownloads() }
    }

    func position(of episodeId: Int) -> Double? { state.positions[episodeId] }

    // MARK: - 聴き終えた

    func isPlayed(_ episodeId: Int) -> Bool { state.played[episodeId] != nil }

    /// 手で「聴き終えた」にする: 聴き終えたときと同じく、キューから外し、位置とファイルを消す（再生中なら止める）
    func markPlayed(_ episode: Episode) {
        if state.nowPlaying?.id == episode.id {
            player.pause()
            player.replaceCurrentItem(with: nil)
            currentTime = 0
            duration = 0
            mutate {
                $0.nowPlaying = nil
                $0.playingQueue = nil
            }
            updateNowPlayingInfo()
        }
        mutate { s in
            s.book.remove(episode.id)
            s.positions[episode.id] = nil
            s.played[episode.id] = Date()
        }
        EpisodeDownloader.deleteFile(for: episode.id)
        downloaded.remove(episode.id)
        Task { await reconcileDownloads() }
    }

    /// 未再生に戻す（位置も消す）
    func markUnplayed(_ episodeId: Int) {
        mutate { s in
            s.played[episodeId] = nil
            s.positions[episodeId] = nil
        }
    }

    // MARK: - AVPlayer の見張り

    private func setupPlayerObservers() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                if t.seconds.isFinite { self.currentTime = t.seconds }
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                if self.isPlaying, Date().timeIntervalSince(self.lastSavedAt) > 5 { self.savePosition() }
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = status != .paused
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
                self.updateNowPlayingInfo()
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended,
                  let opts = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume) else { return }
            MainActor.assumeIsolated { self?.resume() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishCurrent(advance: true) }
        }
    }

    // MARK: - ロック画面・コントロールセンター

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlay() }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForward)]
        c.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: Self.skipForward) }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBack)]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: -Self.skipBack) }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }
            return .success
        }
        c.nextTrackCommand.isEnabled = false
        c.previousTrackCommand.isEnabled = false
    }

    private var artwork: MPMediaItemArtwork?
    private var artworkFor: Int?

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let ep = state.nowPlaying else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: ep.title,
            MPMediaItemPropertyArtist: ep.feedTitle,
            MPMediaItemPropertyAlbumTitle: ep.feedTitle,
            MPMediaItemPropertyMediaType: MPMediaType.podcast.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? state.speed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: state.speed,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork, artworkFor == ep.id { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    private func loadArtwork(for ep: Episode) {
        guard artworkFor != ep.id, let url = ep.artworkURL else { return }
        Task {
            let image: UIImage?
            if let cached = FaviconCache.shared.image(for: url) {
                image = cached
            } else if let (data, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: data) {
                FaviconCache.shared.set(img, for: url)
                image = img
            } else {
                image = nil
            }
            guard let image, state.nowPlaying?.id == ep.id else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            artworkFor = ep.id
            updateNowPlayingInfo()
        }
    }

    // MARK: - DEBUG（スクリーンショット・UI テスト）

    #if DEBUG
    /// 起動引数 -tayoriPodcastPosition: 途中まで聴いたことにする
    func debugSetPosition(_ sec: Double, for episodeId: Int) {
        mutate { $0.positions[episodeId] = sec }
    }

    /// 起動引数 -tayoriPodcastDemo: seed の回でキューを作る（メイン＝いつまじ #42・#40、サブ＝いつまじ #41・Rebuild 436）
    func applyDemoQueues() {
        let eps = newEpisodes
        guard state.book.allEpisodes.isEmpty, eps.count >= 3 else { return }
        let main = state.book.queues[0].id
        let sub = state.book.queues.count > 1 ? state.book.queues[1].id : main
        let byTitle = { (s: String) in eps.first { $0.title.contains(s) } }
        mutate { s in
            if let a = byTitle("#42") { s.book.add(a, to: main, atTop: false) }
            if let b = byTitle("#40") { s.book.add(b, to: main, atTop: false) }
            if let c = byTitle("#41") { s.book.add(c, to: sub, atTop: false) }
            if let d = byTitle("436") { s.book.add(d, to: sub, atTop: false) }
            if let first = s.book.queues.first?.id, let rebuild = eps.first(where: { $0.feedTitle == "Rebuild" }) {
                s.autoAdd[rebuild.feedId] = .queue(first)
            }
        }
        Task { await reconcileDownloads() }
    }
    #endif
}
