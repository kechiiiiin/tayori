import XCTest

/// 画面の動きの確かめ（ローカルの Worker に向けて動かす。先に ../worker で npm run dev と npm run seed）
///   make uitest
final class TayoriUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // 起動時はポッドキャストが開く（2026-11-24）ので、記事のテストは記事のタブから始める
        app.launchArguments = ["-tayoriBaseURL", "http://127.0.0.1:8792", "-tayoriPodcastReset", "-tayoriMainTab", "articles"]
        app.launch()
    }

    /// 記事を開いて、アプリ内 Safari を左端から右へスワイプで閉じる → 一覧に戻り「さっき開いた」が出る
    func testSafariEdgeSwipeReturnsToList() throws {
        let first = app.cells.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "一覧が出ない")
        XCTAssertFalse(returnBar.exists)
        first.tap()
        sleep(4) // Safari 画面が出きるまで
        XCTAssertFalse(app.cells.firstMatch.isHittable, "Safari 画面が出ていない")
        attach("safari")
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(returnBar.waitForExistence(timeout: 5), "左端スワイプで戻っても「さっき開いた」のバーが出ない")
        attach("returned")
    }

    /// 一覧を左へスワイプ → 右隣のカテゴリ、右へ → 左隣。端では止まる
    func testListSwipeSwitchesCategory() throws {
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
        // seed のカテゴリは すべて → 仕事 → 日記・ブログ → 山 → 未分類（「メイン」は無いので最初は「すべて」）
        XCTAssertTrue(tab("仕事").waitForExistence(timeout: 5))
        XCTAssertFalse(tab("仕事").isSelected)
        app.cells.element(boundBy: 1).swipeLeft()
        sleep(2)
        XCTAssertTrue(tab("仕事").isSelected, "左スワイプで右隣（仕事）へ移らない")
        attach("swiped-left")
        app.cells.firstMatch.swipeRight()
        sleep(2)
        XCTAssertFalse(tab("仕事").isSelected, "右スワイプで左隣（すべて）へ戻らない")
        // 端（すべて）でさらに右へ → そのまま（仕事にも未分類にも行かない）
        app.cells.firstMatch.swipeRight()
        sleep(1)
        XCTAssertFalse(tab("仕事").isSelected)
        XCTAssertFalse(tab("未分類").isSelected)
    }

    /// カテゴリのタブ（ラベルは「名前」か「名前, 数」）
    private func tab(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    /// 段階3: 番組はサイト一覧（記事）から消え、ポッドキャストの「番組」タブにアートワークつきで出る。見るのは人の目
    func testPodcastShowsMovedOutOfSites() throws {
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
        app.buttons["サイト"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["サイト"].firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<3 { app.swipeUp() }
        XCTAssertFalse(app.staticTexts["いつまじラジオ"].exists, "番組がサイト一覧に残っている")
        app.tabBars.buttons["ポッドキャスト"].firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label == '番組'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["いつまじラジオ"].firstMatch.waitForExistence(timeout: 10))
        sleep(3) // アートワークの読み込み
        attach("podcast-shows-artwork")
    }

    /// 設定に通知のスイッチがある（撮って人の目で見る）
    func testSettingsHasNotificationToggle() throws {
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
        app.buttons["サイト"].firstMatch.tap()
        app.buttons["カテゴリを作る・設定"].firstMatch.tap() // 右上の ＋ のメニュー
        app.buttons.matching(NSPredicate(format: "label CONTAINS '接続の設定'")).firstMatch.tap()
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label CONTAINS '新着を通知'")).firstMatch.waitForExistence(timeout: 5))
        attach("settings-notification")
    }

    /// 通知: 許可 →（この間に外から `xcrun simctl push` で item_id 入りの通知を送る）→ バナーをタップ → 記事がアプリ内 Safari で開く。
    /// 外から通知を送る段取りが要るので、TEST_RUNNER_TAYORI_PUSH_TEST=1 のときだけ走る
    /// （例: `TEST_RUNNER_TAYORI_PUSH_TEST=1 make uitest TEST_ARGS=-only-testing:TayoriUITests/TayoriUITests/testNotificationTapOpensItem`
    ///  を走らせ、許可が済んだら `xcrun simctl push Tayori-iPhone jp.kechiiiiin.tayori payload.json`。題は「メインのサイト」を含める）
    func testNotificationTapOpensItem() throws {
        guard ProcessInfo.processInfo.environment["TAYORI_PUSH_TEST"] == "1" else { throw XCTSkip("TAYORI_PUSH_TEST=1 のときだけ") }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["許可"].firstMatch
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
        app.terminate() // ホーム画面で通知を受ける（アプリを開いていても出るが、タップで起動する道を確かめる）
        let banner = springboard.otherElements["NotificationShortLookView"].firstMatch
        let anyBanner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'メインのサイト'")).firstMatch
        XCTAssertTrue(anyBanner.waitForExistence(timeout: 60) || banner.exists, "通知が来ない")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "push-banner"
        shot.lifetime = .keepAlways
        add(shot)
        // バナー（画面の上端）を押す。要素の tap は当たらないことがあるので座標で
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        sleep(5)
        XCTAssertEqual(app.state, .runningForeground)
        attach("push-opened")
        XCTAssertFalse(app.cells.firstMatch.isHittable, "記事のアプリ内 Safari が開いていない")
    }

    private var returnBar: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'さっき開いた'")).firstMatch
    }

    private func attach(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
