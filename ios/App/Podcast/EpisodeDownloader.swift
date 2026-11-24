import Foundation
import os

let downloadLog = Logger(subsystem: "jp.kechiiiiin.tayori", category: "downloads")

/// キューに入った回の音声を、バックグラウンドの URLSession で端末へ落とす。
/// - 置き場は Application Support/Episodes/<エピソード id>.<拡張子>（iCloud バックアップから外す）
/// - 既定は Wi-Fi のときだけ（URLRequest.allowsCellularAccess / allowsExpensiveNetworkAccess を設定に合わせる）
/// - 音声は配信元から直接取る（音沙汰の Worker は通さない）
final class EpisodeDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = EpisodeDownloader()
    static let sessionIdentifier = "jp.kechiiiiin.tayori.episodes"

    /// 終わった・失敗した・進んだを PodcastStore へ（メインで呼ぶ）
    var onFinished: (@MainActor (Int) -> Void)?
    var onFailed: (@MainActor (Int, String) -> Void)?
    /// こちらが頼んでいないキャンセル（アプリの強制終了などでシステムが止めた）。まだ要る回なら取り直す
    var onInterrupted: (@MainActor (Int) -> Void)?
    /// こちらから止めた転送の id（キャンセルの知らせを取り直しと取り違えない）
    private var cancelledByUs = Set<Int>()
    private let lock = NSLock()
    var onProgress: (@MainActor (Int, Double) -> Void)?
    /// AppDelegate の handleEventsForBackgroundURLSession から受け取った完了の合図
    var backgroundCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // 携帯回線を使うかは1件ずつ URLRequest で決める（ここは許しておく）
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// 起動時に一度呼ぶ（前回の起動から続いている転送の知らせを受け取れるように）
    func activate() { _ = session }

    // MARK: - 置き場

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Episodes", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    static func fileURL(for episode: Episode) -> URL {
        directory.appendingPathComponent("\(episode.id).\(episode.fileExtension)")
    }

    /// 落としてある回のファイル（無ければ nil）
    static func localFile(for episodeId: Int) -> URL? {
        let prefix = "\(episodeId)."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.first { $0.hasPrefix(prefix) }.map { directory.appendingPathComponent($0) }
    }

    /// 落としてある回の id
    static func downloadedIds() -> Set<Int> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap { Int($0.split(separator: ".").first ?? "") })
    }

    static func deleteFile(for episodeId: Int) {
        if let u = localFile(for: episodeId) { try? FileManager.default.removeItem(at: u) }
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 転送

    func start(_ episode: Episode, allowCellular: Bool) {
        guard let url = episode.audioURL else { return }
        var req = URLRequest(url: url)
        req.allowsCellularAccess = allowCellular
        req.allowsExpensiveNetworkAccess = allowCellular
        req.allowsConstrainedNetworkAccess = allowCellular
        req.setValue("tayori/0.1 (personal podcast player)", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: req)
        // 終わったときに置き場の名前を決められるよう、id と拡張子を持たせる
        task.taskDescription = "\(episode.id).\(episode.fileExtension)"
        task.resume()
        downloadLog.info("start \(episode.id, privacy: .public) cellular=\(allowCellular, privacy: .public)")
    }

    /// いま走っている転送（taskDescription の id → タスク）
    func activeTasks() async -> [Int: URLSessionTask] {
        let tasks = await session.allTasks
        var out: [Int: URLSessionTask] = [:]
        for t in tasks where t.state == .running || t.state == .suspended {
            if let id = Self.episodeId(of: t) { out[id] = t }
        }
        return out
    }

    func cancel(_ episodeId: Int) async {
        let tasks = await activeTasks()
        if let t = tasks[episodeId] { cancel(t) }
    }

    func cancelAll() async {
        for t in await session.allTasks { cancel(t) }
    }

    /// こちらから止める（キャンセルの知らせで取り直さないよう覚えておく）
    func cancel(_ task: URLSessionTask) {
        if let id = Self.episodeId(of: task) {
            lock.lock(); cancelledByUs.insert(id); lock.unlock()
        }
        task.cancel()
    }

    private static func episodeId(of task: URLSessionTask) -> Int? {
        task.taskDescription.flatMap { Int($0.split(separator: ".").first ?? "") }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // このメソッドを抜けると一時ファイルは消えるので、ここで同期で動かす
        guard let name = downloadTask.taskDescription, let id = Self.episodeId(of: downloadTask) else { return }
        downloadLog.info("finished \(id, privacy: .public) status=\((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0, privacy: .public)")
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let cb = onFailed
            Task { @MainActor in cb?(id, "HTTP \(status)") }
            return
        }
        let dest = Self.directory.appendingPathComponent(name)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
            let cb = onFinished
            Task { @MainActor in cb?(id) }
        } catch {
            let cb = onFailed
            Task { @MainActor in cb?(id, "保存できませんでした") }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, let id = Self.episodeId(of: downloadTask) else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let cb = onProgress
        Task { @MainActor in cb?(id, p) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = Self.episodeId(of: task) else { return }
        downloadLog.info("error \(id, privacy: .public) \((error as NSError).code, privacy: .public)")
        if (error as NSError).code == NSURLErrorCancelled {
            lock.lock()
            let ours = cancelledByUs.remove(id) != nil
            lock.unlock()
            if !ours {
                let cb = onInterrupted
                Task { @MainActor in cb?(id) }
            }
            return
        }
        let cb = onFailed
        let msg = (error as NSError).localizedDescription
        Task { @MainActor in cb?(id, msg) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = backgroundCompletion
        backgroundCompletion = nil
        DispatchQueue.main.async { done?() }
    }
}
