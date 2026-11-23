import SwiftUI

@main
struct TayoriApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        #if DEBUG
        ServerConfig.applyLaunchOverride()
        #endif
        LaunchConfig.applyIfPresent()
        // ポッドキャスト: 保存したキューと前回の続きを読み、ロック画面の操作とダウンロードの口をつなぐ
        PodcastStore.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
        }
    }
}
