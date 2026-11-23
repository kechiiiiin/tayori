import XCTest

/// 画面の動きの確かめ（ローカルの Worker に向けて動かす。先に ../worker で npm run dev と npm run seed）
///   make uitest
final class TayoriUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-tayoriBaseURL", "http://127.0.0.1:8792"]
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
