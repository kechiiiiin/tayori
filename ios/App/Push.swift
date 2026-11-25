import SwiftUI
import UIKit
import UserNotifications
import os

let pushLog = Logger(subsystem: "jp.kechiiiiin.tayori", category: "push")

/// プッシュ（Worker が APNs で送る・worker/src/notify.ts）。2種類ある:
/// - お知らせ（alert）: 「メイン」の新着。設定の「通知」がオンで、通知が許可されている端末だけ
/// - サイレント（background・content-available）: 番組に新しい回が入った cron で全端末へ。アプリが裏で起きて
///   PodcastStore.refresh（新着の自動追加 → ダウンロード開始）を走らせる（BackgroundRefresh）
/// 端末トークンは「通知」のオンオフ・許可に関係なく起動のたびに登録する（PUT /api/devices）。
/// alerts = 「通知」オン かつ 許可あり。スイッチをオフにしても外さず alerts=false で登録し直す（サイレントは届き続ける）
/// 通知をタップ → その記事をアプリ内 Safari で開く（戻ると「さっき開いた」のバー）
@MainActor
@Observable
final class PushManager: NSObject {
    static let shared = PushManager()

    private static let enabledKey = "pushEnabled"
    private static let tokenKey = "pushDeviceToken"

    /// 設定の「通知」スイッチ（既定はオン）
    var enabled: Bool = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    /// 通知の許可の状態（設定画面に出す）
    var authorization: UNAuthorizationStatus = .notDetermined
    /// 最後に登録できたか（設定画面に出す。nil = まだ）
    var lastError: String?

    private weak var model: AppModel?
    /// 起動前にタップされた通知の記事（model がつながったら開く）
    private var pendingItemId: Int?

    private var token: String? {
        get { UserDefaults.standard.string(forKey: Self.tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.tokenKey) }
    }

    /// RootView から: 一覧の model をつなぎ、オンなら許可を求めて登録する
    func attach(_ model: AppModel) async {
        self.model = model
        if let id = pendingItemId {
            pendingItemId = nil
            await model.openItem(id: id)
        }
        await refreshAuthorization()
        await requestAndRegister()
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 前面に戻った: 設定アプリで通知の許可が変わっていたら登録し直す（alerts を合わせる）
    func resync() async {
        let before = authorization
        await refreshAuthorization()
        if authorization != before { await requestAndRegister() }
    }

    /// お知らせを受け取る（Worker に alerts として送る）
    var alertsWanted: Bool {
        enabled && (authorization == .authorized || authorization == .provisional || authorization == .ephemeral)
    }

    /// 設定のスイッチ。オフでも端末は外さない（alerts=false で登録し直す・サイレントプッシュは届く）
    func setEnabled(_ on: Bool) async {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if !on, let t = token {
            await upload(token: t) // トークンは手元にある。その場で alerts=false にする
        } else {
            await requestAndRegister()
        }
    }

    /// 「通知」オンで未決なら許可を求め、どの場合も端末トークンを取り直す（サイレントプッシュは許可が要らない）
    private func requestAndRegister() async {
        if enabled && authorization == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
        }
        // トークンは AppDelegate の didRegisterForRemoteNotificationsWithDeviceToken に来る（→ didRegister で Worker へ）
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// APNs から端末トークンが来た: Worker へ登録（alerts = 「通知」オン かつ 許可あり）
    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        token = hex
        Task { await upload(token: hex) }
    }

    private func upload(token hex: String) async {
        guard TayoriAPI.shared.isConfigured else { return }
        let alerts = alertsWanted
        pushLog.info("register alerts=\(alerts, privacy: .public)")
        do {
            try await TayoriAPI.shared.registerDevice(token: hex, environment: Self.apsEnvironment, alerts: alerts)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func didFailToRegister(_ error: Error) {
        lastError = (error as NSError).localizedDescription
    }

    /// 通知をタップした
    func open(itemId: Int) {
        if let model {
            Task { await model.openItem(id: itemId) }
        } else {
            pendingItemId = itemId
        }
    }

    /// このビルドの APNs の環境。開発署名（Xcode・devicectl で入れたもの）は埋め込みの
    /// プロファイルが aps-environment=development → sandbox。TestFlight・App Store はプロファイルが無い → production
    static var apsEnvironment: String {
        #if targetEnvironment(simulator)
        return "development"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1) else { return "production" }
        let compact = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return compact.contains("<key>aps-environment</key><string>development</string>") ? "development" : "production"
        #endif
    }
}

extension PushManager: UNUserNotificationCenterDelegate {
    /// アプリを開いているときも出す
    // async 版の delegate は完了をメインスレッド外で返して UIKit のアサーションで落ちる（タップで起動したとき）。
    // 完了ハンドラ版を使い、メインで呼ぶ
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { completionHandler([.banner, .list, .sound]) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["item_id"] as? NSNumber)?.intValue
        DispatchQueue.main.async {
            if let id { PushManager.shared.open(itemId: id) }
            completionHandler()
        }
    }
}

/// 端末トークンを受け取る口（SwiftUI の App には無いので UIApplicationDelegate で）
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 起動直後の通知のタップを取りこぼさないよう、ここで delegate を据える
        UNUserNotificationCenter.current().delegate = PushManager.shared
        // 保険の BGAppRefreshTask（登録は起動が終わる前でなければならない）。裏に回るたびに予約する
        BackgroundRefresh.register()
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BackgroundRefresh.schedule() }
        }
        return true
    }

    /// サイレントプッシュ（番組の新しい回）: 新着を取り、キューへ足してダウンロードを始める。completionHandler は必ず1回
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let aps = userInfo["aps"] as? [AnyHashable: Any]
        let available = aps?["content-available"]
        pushLog.info("remote notification content-available=\(String(describing: available), privacy: .public)")
        guard let available, (available as? NSNumber)?.intValue == 1 || (available as? String) == "1" else { return completionHandler(.noData) }
        MainActor.assumeIsolated {
            _ = BackgroundRefresh.run(reason: "push", timeout: BackgroundRefresh.pushTimeout) { outcome in
                completionHandler(outcome.fetchResult)
            }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushManager.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { PushManager.shared.didFailToRegister(error) }
    }

    /// ポッドキャストのバックグラウンドのダウンロードが終わった（アプリが止まっていたら起こされる）
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == EpisodeDownloader.sessionIdentifier else { return completionHandler() }
        EpisodeDownloader.shared.backgroundCompletion = completionHandler
        EpisodeDownloader.shared.activate()
    }
}
