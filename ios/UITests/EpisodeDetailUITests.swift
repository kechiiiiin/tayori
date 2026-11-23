import XCTest

/// 2026-11-24 の手直し（ローカルの Worker・seed。先に ../worker で npm run dev と npm run seed）
/// - 回の行をタップすると再生せずに詳細ページ（番組の回・新着・キューの3か所）
/// - 詳細の再生ボタン・キューへの追加・概要のリンクはアプリ内 Safari
/// - キューは右端の取っ手（≡）をドラッグで並べ替え（編集モードなし）・左スワイプで外す
/// - 番組名・アートワークから番組の画面へ（詳細・全画面プレーヤー・新着とキューの行）
/// - 下のタブは「ポッドキャスト｜記事」の順で、起動するとポッドキャスト
/// - 聴き終えた: 詳細で切り替え・一覧に印・キューから外れる
///   make uitest TEST_ARGS=-only-testing:TayoriUITests/EpisodeDetailUITests
final class EpisodeDetailUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ extra: [String] = [], mainTab: Bool = true) {
        app.launchArguments = ["-tayoriBaseURL", "http://127.0.0.1:8792", "-tayoriPodcastReset", "-tayoriPodcastDemo"]
            + (mainTab ? ["-tayoriMainTab", "podcasts"] : []) + extra
        app.launch()
    }

    // MARK: - 行のタップは詳細（再生しない）

    func testRowTapOpensDetailWithoutPlayingInQueueNewAndShow() throws {
        launch()
        XCTAssertTrue(tab("メイン").waitForExistence(timeout: 15))
        // キュー
        let q = text("#42")
        XCTAssertTrue(q.waitForExistence(timeout: 10))
        q.tap()
        assertDetail(containing: "#42")
        attach("detail-from-queue")
        back()
        // 新着
        tab("新着").tap()
        let n = text("434: Agent Leadership")
        XCTAssertTrue(n.waitForExistence(timeout: 10))
        n.tap()
        assertDetail(containing: "434")
        back()
        // 番組の回
        tab("番組").tap()
        app.staticTexts["Rebuild"].firstMatch.tap()
        let s = text("435: AI Agents")
        XCTAssertTrue(s.waitForExistence(timeout: 10))
        s.tap()
        assertDetail(containing: "435")
        attach("detail-from-show")
    }

    // MARK: - 詳細: 再生・キュー・概要のリンク

    func testDetailPlayQueueAndNotesLink() throws {
        launch()
        XCTAssertTrue(tab("新着").waitForExistence(timeout: 15))
        tab("新着").tap()
        text("434: Agent Leadership").tap()
        assertDetail(containing: "434")
        let state = app.staticTexts["episodeDetailQueueState"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertEqual(state.label, "キューに入っていません")
        // キューへ → サブの末尾へ
        app.buttons["キューへ追加"].firstMatch.tap()
        let item = app.buttons["サブの末尾へ"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(waitFor(state, contains: "サブの3番目", timeout: 5), "キューに入った表示にならない: \(state.label)")
        attach("detail-queued")
        // 外す
        app.buttons["キューから外す"].firstMatch.tap()
        XCTAssertTrue(waitFor(state, contains: "入っていません", timeout: 5))
        // 再生ボタン → ミニプレーヤーにその回
        app.buttons["episodeDetailPlay"].firstMatch.tap()
        XCTAssertTrue(waitFor(app.staticTexts["nowPlayingTitle"], contains: "434", timeout: 30), "詳細の再生ボタンで再生されない")
        XCTAssertTrue(waitFor(app.buttons["episodeDetailPlay"], contains: "一時停止", timeout: 30))
        attach("detail-playing")
        // 概要（#42）: 段落・箇条書き・リンク。画像と script は出ない
        back()
        text("#42").tap()
        let notes = app.staticTexts["episodeDetailNotes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10), "概要が出ない")
        XCTAssertTrue(notes.label.contains("話したこと"))
        XCTAssertFalse(notes.label.contains("alert"))
        app.swipeUp()
        let link = app.links["番組のページ"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5), "概要のリンクが無い")
        link.tap()
        sleep(4)
        XCTAssertFalse(app.staticTexts["episodeDetailTitle"].isHittable && notes.isHittable, "アプリ内 Safari が開いていない")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == '完了' OR label == 'Done'")).firstMatch.exists, "SFSafariViewController の完了ボタンが無い")
        attach("notes-link-safari")
    }

    // MARK: - キュー: 取っ手で並べ替え・スワイプで外す

    func testQueueDragHandleReordersAndSwipeStillRemoves() throws {
        launch()
        XCTAssertTrue(tab("メイン").waitForExistence(timeout: 15))
        let a = text("#42"), b = text("#40")
        XCTAssertTrue(a.waitForExistence(timeout: 10) && b.exists)
        XCTAssertLessThan(a.frame.minY, b.frame.minY)
        attach("queue-before-drag")
        // #42 の行の右端（取っ手）をつかんで #40 の下まで引く。編集モード（並べ替えボタン）は無い
        XCTAssertFalse(app.buttons["並べ替え"].exists, "並べ替えボタンが残っている")
        let window = app.windows.firstMatch
        let handle = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.frame.maxX - 30, dy: a.frame.midY + 10))
        let target = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.frame.maxX - 30, dy: b.frame.maxY + 50))
        handle.press(forDuration: 0.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        XCTAssertGreaterThan(text("#42").frame.minY, text("#40").frame.minY, "取っ手のドラッグで並びが変わらない")
        attach("queue-after-drag")
        // 並びは保存され、詳細もタップで開く
        text("#40").tap()
        assertDetail(containing: "#40")
        XCTAssertTrue(waitFor(app.staticTexts["episodeDetailQueueState"], contains: "メインの1番目", timeout: 5))
        back()
        // 左スワイプ → 外す
        text("#42").swipeLeft()
        let remove = app.buttons["外す"].firstMatch
        if remove.waitForExistence(timeout: 3) { remove.tap() }
        XCTAssertTrue(waitFor(tab("メイン"), equals: "メイン, 1", timeout: 5), "スワイプで外せない")
        // 右スワイプ → 移す
        text("#40").swipeRight()
        let move = app.buttons["移す"].firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 3), "右スワイプの「移す」が無い")
        move.tap()
        app.buttons["サブの末尾へ"].firstMatch.tap()
        XCTAssertTrue(waitFor(tab("サブ"), equals: "サブ, 3", timeout: 5))
    }

    // MARK: - 番組の画面へ

    func testArtworkAndShowNameOpenShow() throws {
        launch()
        XCTAssertTrue(tab("新着").waitForExistence(timeout: 15))
        tab("新着").tap()
        // 行のアートワーク
        let art = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Rebuildの番組を開く'")).firstMatch
        XCTAssertTrue(art.waitForExistence(timeout: 10))
        art.tap()
        XCTAssertTrue(app.navigationBars["Rebuild"].waitForExistence(timeout: 5), "行のアートワークで番組の画面が開かない")
        XCTAssertFalse(app.staticTexts["episodeDetailTitle"].exists)
        back()
        // キューの行のアートワーク
        tab("メイン").tap()
        let qArt = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'いつまじラジオの番組を開く'")).firstMatch
        XCTAssertTrue(qArt.waitForExistence(timeout: 5))
        qArt.tap()
        XCTAssertTrue(app.navigationBars["いつまじラジオ"].waitForExistence(timeout: 5), "キューの行のアートワークで番組の画面が開かない")
        // その番組の回 → 詳細 → 番組名で戻る（重ねない）
        text("#41").tap()
        assertDetail(containing: "#41")
        app.buttons["episodeDetailShow"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["いつまじラジオ"].waitForExistence(timeout: 5))
        back()
        XCTAssertTrue(tab("メイン").waitForExistence(timeout: 5), "番組 → 回 → 番組 と重なっている")
        // 詳細のアートワーク（新着から）
        tab("新着").tap()
        text("436: Elephant").tap()
        assertDetail(containing: "436")
        app.buttons["episodeDetailArtwork"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Rebuild"].waitForExistence(timeout: 5), "詳細のアートワークで番組の画面が開かない")
        attach("show-from-detail-artwork")
    }

    func testFullPlayerShowNameClosesPlayerAndOpensShow() throws {
        launch(["-tayoriPodcastPlay", "-tayoriPlayer", "open"])
        let show = app.buttons["playerShow"].firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 20), "全画面プレーヤーが出ない")
        attach("full-player-show-link")
        show.tap()
        XCTAssertTrue(app.navigationBars["いつまじラジオ"].waitForExistence(timeout: 8), "プレーヤーの番組名で番組の画面が開かない")
        XCTAssertFalse(app.buttons["再生速度"].exists, "全画面プレーヤーが閉じていない")
        // アートワークでも（記事のタブにいても、ポッドキャストのタブへ切り替わる）
        app.tabBars.buttons["記事"].firstMatch.tap()
        app.otherElements["miniPlayer"].firstMatch.tap()
        let art = app.buttons["playerArtwork"].firstMatch
        XCTAssertTrue(art.waitForExistence(timeout: 8))
        art.tap()
        XCTAssertTrue(app.navigationBars["いつまじラジオ"].waitForExistence(timeout: 8), "記事のタブからプレーヤーのアートワークで番組の画面へ行けない")
        XCTAssertTrue(app.tabBars.buttons["ポッドキャスト"].isSelected)
    }

    // MARK: - 下のタブの並びと起動時

    func testPodcastsTabIsFirstAndOpensOnLaunch() throws {
        launch([], mainTab: false)
        XCTAssertTrue(tab("メイン").waitForExistence(timeout: 15), "起動してポッドキャストが開かない")
        let buttons = app.tabBars.buttons
        XCTAssertEqual(buttons.element(boundBy: 0).label, "ポッドキャスト")
        XCTAssertEqual(buttons.element(boundBy: 1).label, "記事")
        XCTAssertTrue(buttons["ポッドキャスト"].isSelected)
        attach("launch-podcasts-first")
        buttons["記事"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10), "記事のページが出ない")
    }

    // MARK: - 聴き終えた

    func testMarkPlayedRemovesFromQueueAndShowsInLists() throws {
        launch()
        XCTAssertTrue(tab("メイン").waitForExistence(timeout: 15))
        text("#42").tap()
        assertDetail(containing: "#42")
        let toggle = app.buttons["episodeDetailPlayedToggle"].firstMatch
        XCTAssertTrue(toggle.label.contains("聴き終えたにする"))
        toggle.tap()
        XCTAssertTrue(waitFor(toggle, contains: "未再生に戻す", timeout: 5))
        XCTAssertTrue(waitFor(app.staticTexts["episodeDetailQueueState"], contains: "入っていません", timeout: 5), "聴き終えてもキューに残る")
        attach("detail-played")
        back()
        XCTAssertTrue(waitFor(tab("メイン"), equals: "メイン, 1", timeout: 5))
        // 新着で印
        tab("新着").tap()
        let row = text("#42")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let mark = app.images.matching(NSPredicate(format: "label == '聴き終えた'")).firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 5), "新着に聴き終えた印が無い")
        XCTAssertLessThan(abs(mark.frame.midY - row.frame.maxY), 60)
        attach("new-with-played")
        // 長押しメニューで未再生に戻す
        row.press(forDuration: 1.2)
        let unplay = app.buttons["未再生に戻す"].firstMatch
        XCTAssertTrue(unplay.waitForExistence(timeout: 5), "長押しメニューに「未再生に戻す」が無い")
        unplay.tap()
        XCTAssertFalse(app.images.matching(NSPredicate(format: "label == '聴き終えた'")).firstMatch.waitForExistence(timeout: 2))
    }

    // MARK: - 補助

    private func assertDetail(containing s: String, file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts["episodeDetailTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "詳細ページが開かない", file: file, line: line)
        XCTAssertTrue(title.label.contains(s), "別の回の詳細: \(title.label)", file: file, line: line)
        XCTAssertFalse(app.staticTexts["nowPlayingTitle"].exists, "行のタップで再生された", file: file, line: line)
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func text(_ s: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND identifier != 'nowPlayingTitle' AND identifier != 'episodeDetailTitle'", s)).firstMatch
    }

    private func tab(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
    }

    private func waitFor(_ e: XCUIElement, contains s: String, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "exists == true AND label CONTAINS %@", s)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: e)], timeout: timeout) == .completed
    }

    private func waitFor(_ e: XCUIElement, equals s: String, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "exists == true AND label == %@", s)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: e)], timeout: timeout) == .completed
    }

    private func attach(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
