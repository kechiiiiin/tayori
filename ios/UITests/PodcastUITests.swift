import XCTest

/// 段階3 ポッドキャスト（ローカルの Worker・seed の実在の公開回を再生する。先に ../worker で npm run dev と npm run seed）
///   make uitest TEST_ARGS=-only-testing:TayoriUITests/PodcastUITests
final class PodcastUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ extra: [String]) {
        app.launchArguments = ["-tayoriBaseURL", "http://127.0.0.1:8792", "-tayoriPodcastReset", "-tayoriPodcastDemo",
                               "-tayoriMainTab", "podcasts"] + extra
        app.launch()
    }

    /// 下のタブで記事／ポッドキャストを切り替えられ、記事のページは今までどおり（カテゴリのタブ・行）
    func testTabBarSwitchesArticlesAndPodcasts() throws {
        launch([])
        XCTAssertTrue(tab("メイン").waitForExistence(timeout: 15), "ポッドキャストのキューのタブが出ない")
        XCTAssertTrue(tab("サブ").exists)
        XCTAssertTrue(tab("新着").exists)
        XCTAssertTrue(tab("番組").exists)
        attach("podcast-queue")
        app.tabBars.buttons["記事"].firstMatch.tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10), "記事の一覧が出ない")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '仕事'")).firstMatch.exists, "記事のカテゴリのタブが無い")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'いつまじラジオ'")).firstMatch.exists, "記事一覧に番組の回が混ざっている")
        attach("articles")
        app.tabBars.buttons["ポッドキャスト"].firstMatch.tap()
        XCTAssertTrue(tab("メイン").waitForExistence(timeout: 5))
    }

    /// 新着の回の ＋ から「サブの先頭へ」→ サブのキューの先頭に入る
    func testAddToQueueFromNewEpisodes() throws {
        launch([])
        XCTAssertTrue(tab("新着").waitForExistence(timeout: 15))
        tab("新着").tap()
        let row = app.staticTexts["434: Agent Leadership (Matz)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        // 434 の行の ＋（キューに入れる）
        let plus = app.buttons.matching(identifier: "キューに入れる")
        var target: XCUIElement?
        for i in 0..<plus.count {
            let b = plus.element(boundBy: i)
            if abs(b.frame.midY - row.frame.midY) < 40 { target = b; break }
        }
        XCTAssertNotNil(target, "434 の行の ＋ が見つからない")
        target!.tap()
        let item = app.buttons["サブの先頭へ"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "キューのメニューが出ない")
        attach("add-to-queue-menu")
        item.tap()
        tab("サブ").tap()
        let added = text(containing: "434: Agent Leadership")
        let wasHead = text(containing: "#41")
        XCTAssertTrue(added.waitForExistence(timeout: 5), "サブに入っていない")
        XCTAssertTrue(wasHead.exists)
        XCTAssertLessThan(added.frame.minY, wasHead.frame.minY, "サブの先頭に入っていない")
        XCTAssertEqual(tab("サブ").label, "サブ, 3")
        attach("sub-after-add")
    }

    /// キューの連鎖: 各回を末尾の 6 秒前から再生して聴き終えさせ、
    /// メイン（#42 → #40）→ 空になったら隣のサブの先頭（#41 → 436）→ 最後のキューを聴き終えたら止まる
    /// 配信元からの読み込みに左右されないよう、キューの4回が端末に落ちてから（＝機内モードでも鳴る道で）再生する
    func testQueueAdvancesToNextQueueAndStops() throws {
        launch(["-tayoriSeekNearEnd", "6"])
        XCTAssertTrue(tab("メイン").waitForExistence(timeout: 15))
        tab("サブ").tap()
        XCTAssertTrue(waitForDownloads(2, timeout: 240), "サブの回が落ちてこない")
        tab("メイン").tap()
        XCTAssertTrue(waitForDownloads(2, timeout: 240), "メインの回が落ちてこない")
        let head = text(containing: "#42")
        XCTAssertTrue(head.waitForExistence(timeout: 10))
        XCTAssertLessThan(head.frame.minY, text(containing: "#40").frame.minY, "メインの先頭が #42 でない")
        head.tap()
        let title = app.staticTexts["nowPlayingTitle"]
        XCTAssertTrue(waitFor(title, contains: "#42", timeout: 30), "再生が始まらない")
        attach("playing-42")
        XCTAssertTrue(waitFor(title, contains: "#40", timeout: 90), "メインの次の回（#40）へ進まない")
        XCTAssertTrue(waitFor(title, contains: "#41", timeout: 90), "メインを聴き終えても隣のサブの先頭（#41）へ進まない")
        attach("advanced-to-sub")
        XCTAssertTrue(waitFor(title, contains: "436", timeout: 90), "サブの次の回（436）へ進まない")
        // 最後のキューを聴き終えた → 止まる（ミニプレーヤーが消え、キューは空）
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: title)
        waitForExpectations(timeout: 90)
        XCTAssertEqual(tab("メイン").label, "メイン")
        XCTAssertEqual(tab("サブ").label, "サブ")
        attach("stopped")
    }

    /// 全画面プレーヤー: 速度 ＋ で 0.1 上がり、30秒送りで位置が進む
    func testFullPlayerSpeedAndSkip() throws {
        launch(["-tayoriPodcastPlay", "-tayoriPlayer", "open"])
        let speed = app.buttons["再生速度"].firstMatch
        XCTAssertTrue(speed.waitForExistence(timeout: 20), "全画面プレーヤーが出ない")
        let before = speed.value as? String
        app.buttons["速くする"].firstMatch.tap()
        let after = speed.value as? String
        XCTAssertNotEqual(before, after)
        app.buttons["30秒送る"].firstMatch.tap()
        attach("full-player")
        app.buttons["遅くする"].firstMatch.tap()
        XCTAssertEqual(speed.value as? String, before)
    }

    /// いま見えているキューで「ダウンロード済み」の印が n 個そろうまで待つ
    private func waitForDownloads(_ n: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.images.matching(NSPredicate(format: "label == 'ダウンロード済み'")).count >= n { return true }
            sleep(2)
        }
        return false
    }

    private func text(containing s: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND identifier != 'nowPlayingTitle'", s)).firstMatch
    }

    private func waitFor(_ e: XCUIElement, contains s: String, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "exists == true AND label CONTAINS %@", s)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: e)], timeout: timeout) == .completed
    }

    /// 上のタブ（ラベルは「名前」か「名前, 数」）
    private func tab(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
    }

    private func attach(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
