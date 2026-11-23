import XCTest

/// ポッドキャストの上のタブを一覧の左右スワイプで切り替える（2026-11-24・記事のカテゴリと同じ手触り）
/// - 新着・番組: 一覧のどこでも（番組は右へだけ・左へは行の「外す」に譲る）
/// - キュー: 行の上の横スワイプは行の操作（外す・移す）が優先・行の無い余白と見出しの帯で隣のタブへ
/// ローカルの Worker・seed（先に ../worker で npm run dev と npm run seed）
///   make uitest TEST_ARGS=-only-testing:TayoriUITests/PodcastTabSwipeUITests
final class PodcastTabSwipeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments = ["-tayoriBaseURL", "http://127.0.0.1:8792", "-tayoriPodcastReset", "-tayoriPodcastDemo",
                               "-tayoriMainTab", "podcasts"] + extra
        app.launch()
    }

    /// 新着 ⇄ 番組 ⇄ キュー（サブ → メイン）を一覧の左右スワイプで行き来し、端では止まる
    func testSwipeSwitchesNewShowsAndQueues() throws {
        launch(["-tayoriPodcastTab", "new"])
        XCTAssertTrue(tab("新着").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["434: Agent Leadership (Matz)"].firstMatch.waitForExistence(timeout: 10), "新着が出ない")
        XCTAssertTrue(tab("新着").isSelected)

        // 新着 → 左へ → 番組
        swipe(.left)
        XCTAssertTrue(waitSelected("番組"), "新着で左へスワイプしても番組へ移らない")
        XCTAssertTrue(app.staticTexts["いつまじラジオ"].firstMatch.waitForExistence(timeout: 5))
        // 番組は右端。行の無い下の方でさらに左へ → そのまま
        swipe(.left, at: 0.85)
        XCTAssertTrue(tab("番組").isSelected, "右端の番組から左へ動いた")
        // 番組 → 右へ → 新着
        swipe(.right)
        XCTAssertTrue(waitSelected("新着"), "番組で右へスワイプしても新着へ戻らない")
        // 新着 → 右へ → サブ（キューの右端）
        swipe(.right)
        XCTAssertTrue(waitSelected("サブ"), "新着で右へスワイプしてもキュー（サブ）へ移らない")
        // サブの行は2つだけなので、下の余白で右へ → メイン
        swipe(.right, at: 0.75)
        XCTAssertTrue(waitSelected("メイン"), "キューの余白で右へスワイプしても左隣のキューへ移らない")
        // メインは左端。さらに右へ → そのまま
        swipe(.right, at: 0.75)
        XCTAssertTrue(tab("メイン").isSelected, "左端のメインから右へ動いた")
        // 見出しの帯（「2回 · 残り…」）の上で左へ → サブ
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2回'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        header.swipeLeft()
        XCTAssertTrue(waitSelected("サブ"), "キューの見出しの帯で左へスワイプしても右隣へ移らない")
    }

    /// タブを直接タップしても切り替わる（アニメつき・離れたタブへも）
    func testTapTabStillSwitches() throws {
        launch()
        XCTAssertTrue(tab("メイン").waitForExistence(timeout: 15))
        tab("番組").tap()
        XCTAssertTrue(waitSelected("番組"))
        tab("メイン").tap()
        XCTAssertTrue(waitSelected("メイン"))
    }

    /// キューの行の上の横スワイプは行の操作のまま（左へで「外す」・右へで「移す」）で、タブは動かない
    func testQueueRowSwipeKeepsRowActions() throws {
        launch()
        XCTAssertTrue(tab("メイン").waitForExistence(timeout: 15))
        let row = text("#42")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        XCTAssertTrue(app.buttons["外す"].firstMatch.waitForExistence(timeout: 3), "行の左スワイプで「外す」が出ない")
        XCTAssertTrue(tab("メイン").isSelected, "行の左スワイプでタブが動いた")
        app.buttons["外す"].firstMatch.tap()
        XCTAssertTrue(waitFor(tab("メイン"), equals: "メイン, 1", timeout: 5), "スワイプで外せない")
        text("#40").swipeRight()
        XCTAssertTrue(app.buttons["移す"].firstMatch.waitForExistence(timeout: 3), "行の右スワイプで「移す」が出ない")
        XCTAssertTrue(tab("メイン").isSelected, "行の右スワイプでタブが動いた")
    }

    /// 縦のスクロールではタブが動かない
    func testVerticalScrollDoesNotSwitch() throws {
        launch(["-tayoriPodcastTab", "new"])
        XCTAssertTrue(app.staticTexts["434: Agent Leadership (Matz)"].firstMatch.waitForExistence(timeout: 15))
        let list = app.collectionViews.firstMatch
        list.swipeUp()
        list.swipeDown()
        sleep(1)
        XCTAssertTrue(tab("新着").isSelected, "縦のスクロールでタブが動いた")
        // 斜め（縦が勝つ）でも動かない
        let w = app.windows.firstMatch
        let start = w.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.7))
        let end = w.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)
        XCTAssertTrue(tab("新着").isSelected, "縦が勝つ斜めのスワイプでタブが動いた")
    }

    // MARK: - 手伝い

    private enum Direction { case left, right }

    /// 画面の高さ at（0〜1）のところで横に払う
    private func swipe(_ d: Direction, at y: CGFloat = 0.55) {
        let w = app.windows.firstMatch
        let a = w.coordinate(withNormalizedOffset: CGVector(dx: d == .left ? 0.8 : 0.2, dy: y))
        let b = w.coordinate(withNormalizedOffset: CGVector(dx: d == .left ? 0.2 : 0.8, dy: y))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
    }

    private func waitSelected(_ name: String, timeout: TimeInterval = 3) -> Bool {
        let p = NSPredicate(format: "isSelected == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: tab(name))], timeout: timeout) == .completed
    }

    private func waitFor(_ e: XCUIElement, equals s: String, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "label == %@", s)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: e)], timeout: timeout) == .completed
    }

    private func text(_ s: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND identifier != 'nowPlayingTitle'", s)).firstMatch
    }

    private func tab(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
    }
}
