import SwiftUI
import UIKit
import UserNotifications

/// 「メイン」の新着のプッシュ通知（Worker が APNs で送る・worker/src/notify.ts）。
/// - 設定で オン（既定）のあいだ、起動のたびに許可を確かめ、端末トークンを Worker に登録する（PUT /api/devices）
/// - オフにしたら Worker から外す（DELETE /api/devices/:token）
/// - 通知をタップ → その記事をアプリ内 Safari で開く（戻ると「さっき開いた」のバー）
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
        if enabled { await requestAndRegister() }
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 設定のスイッチ
    func setEnabled(_ on: Bool) async {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            await requestAndRegister()
        } else if let t = token {
            do {
                try await TayoriAPI.shared.unregisterDevice(token: t)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func requestAndRegister() async {
        let center = UNUserNotificationCenter.current()
        if authorization == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
        }
        guard authorization == .authorized || authorization == .provisional || authorization == .ephemeral else { return }
        // トークンは AppDelegate の didRegisterForRemoteNotificationsWithDeviceToken に来る
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// APNs から端末トークンが来た
    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        token = hex
        guard enabled, TayoriAPI.shared.isConfigured else { return }
        Task {
            do {
                try await TayoriAPI.shared.registerDevice(token: hex, environment: Self.apsEnvironment)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
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
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushManager.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { PushManager.shared.didFailToRegister(error) }
    }
}
