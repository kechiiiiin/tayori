import BackgroundTasks
import UIKit

/// アプリを開かなくても番組の新しい回をキューへ足し、ダウンロードを始める（裏起動の入り口）。
/// 1. サイレントプッシュ（Worker が番組に新しい回が入った cron で送る・AppDelegate の didReceiveRemoteNotification）
/// 2. 保険の BGAppRefreshTask（<bundle id>.refresh・裏に回るたび 1 時間後以降で予約。いつ起こすかは iOS 次第）
/// どちらも PodcastStore.refresh（applyAutoAdd → reconcileDownloads）を走らせるだけ。
/// ダウンロードはバックグラウンドの URLSession なので、アプリが止まっても続く。再生・画面には触らない
@MainActor
enum BackgroundRefresh {
    static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "jp.kechiiiiin.tayori") + ".refresh"
    /// サイレントプッシュの持ち時間は約 30 秒。余裕を見て打ち切る
    static let pushTimeout: Swift.Duration = .seconds(25)
    /// BGAppRefreshTask も約 30 秒（expirationHandler が来たらそこで打ち切る）
    static let taskTimeout: Swift.Duration = .seconds(25)
    static let interval: TimeInterval = 3600

    /// 新着を取りに行く。completion は必ずちょうど1回（終わった・打ち切った のどちらか早い方）。
    /// 戻り値を呼ぶと打ち切る（BGTask の expirationHandler 用）
    @discardableResult
    static func run(reason: String, timeout: Swift.Duration, completion: @escaping (PodcastStore.RefreshOutcome) -> Void) -> () -> Void {
        pushLog.info("background refresh start reason=\(reason, privacy: .public)")
        // 裏起動では App.init で済んでいるはずだが、念のため（2回目以降は何もしない）
        PodcastStore.shared.configure()
        var done = false
        var timer: Task<Void, Never>?
        func finish(_ outcome: PodcastStore.RefreshOutcome, _ why: String) {
            guard !done else { return }
            done = true
            timer?.cancel()
            pushLog.info("background refresh end reason=\(reason, privacy: .public) outcome=\(String(describing: outcome), privacy: .public) by=\(why, privacy: .public)")
            completion(outcome)
        }
        let work = Task { finish(await PodcastStore.shared.refresh(), "done") }
        timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            work.cancel()
            finish(.failed, "timeout")
        }
        return {
            work.cancel()
            finish(.failed, "expired")
        }
    }

    /// didFinishLaunching で（起動が終わる前に登録しなければならない）
    static func register() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            MainActor.assumeIsolated { handle(task) }
        }
        pushLog.info("bgtask register \(taskIdentifier, privacy: .public) ok=\(ok, privacy: .public)")
    }

    /// 次を予約（同じ識別子の予約は置き換わる）。シミュレータでは失敗する（BGTaskScheduler が使えない）
    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(req)
            pushLog.info("bgtask scheduled")
        } catch {
            pushLog.info("bgtask submit failed \((error as NSError).code, privacy: .public)")
        }
    }

    private static func handle(_ task: BGTask) {
        schedule() // 次を先に予約しておく
        let cancel = run(reason: "bgtask", timeout: taskTimeout) { outcome in
            task.setTaskCompleted(success: outcome != .failed)
        }
        task.expirationHandler = { DispatchQueue.main.async { cancel() } }
    }
}

extension PodcastStore.RefreshOutcome {
    var fetchResult: UIBackgroundFetchResult {
        switch self {
        case .newData: .newData
        case .noData: .noData
        case .failed: .failed
        }
    }
}
