import XCTest
@testable import Tayori

/// キューの決まり（設計書 段階3）: 先頭／末尾への追加・並べ替え・別のキューへ移す・聴き終えたら隣のキューの先頭へ（最後なら止まる）・新着の自動追加
final class QueueBookTests: XCTestCase {
    private func ep(_ id: Int, feed: Int = 1, daysAgo: Double = 0) -> Episode {
        let d = Date().addingTimeInterval(-daysAgo * 86400)
        let iso = ISO8601DateFormatter().string(from: d)
        return Episode(id: id, feedId: feed, feedTitle: "番組\(feed)", feedImageUrl: nil, title: "回\(id)", url: nil,
                       publishedAt: iso, sortAt: iso, enclosureUrl: "https://cdn.example/\(id).mp3", enclosureType: "audio/mpeg", durationSec: 600)
    }

    private func ids(_ b: QueueBook, _ i: Int) -> [Int] { b.queues[i].episodes.map(\.id) }

    func testInitialHasMainAndSub() {
        let b = QueueBook.initial()
        XCTAssertEqual(b.queues.map(\.name), ["メイン", "サブ"])
    }

    func testAddTopAndBottomAndNoDuplicates() {
        var b = QueueBook.initial()
        let main = b.queues[0].id, sub = b.queues[1].id
        b.add(ep(1), to: main, atTop: false)
        b.add(ep(2), to: main, atTop: false)
        b.add(ep(3), to: main, atTop: true)
        XCTAssertEqual(ids(b, 0), [3, 1, 2])
        // 同じ回を別のキューへ入れたら移る（1つの回は1つのキューにだけ）
        b.add(ep(1), to: sub, atTop: true)
        XCTAssertEqual(ids(b, 0), [3, 2])
        XCTAssertEqual(ids(b, 1), [1])
        // 同じキューの末尾へ入れ直すと動く
        b.add(ep(3), to: main, atTop: false)
        XCTAssertEqual(ids(b, 0), [2, 3])
        XCTAssertEqual(b.location(of: 1)?.queue, sub)
    }

    func testMoveWithinQueueAndRemove() {
        var b = QueueBook.initial()
        let main = b.queues[0].id
        for i in 1...4 { b.add(ep(i), to: main, atTop: false) }
        b.move(in: main, from: IndexSet(integer: 0), to: 3) // 1 を 3 の後ろへ
        XCTAssertEqual(ids(b, 0), [2, 3, 1, 4])
        b.move(in: main, from: IndexSet(integer: 3), to: 0) // 4 を先頭へ
        XCTAssertEqual(ids(b, 0), [4, 2, 3, 1])
        b.remove(3)
        XCTAssertEqual(ids(b, 0), [4, 2, 1])
    }

    func testQueuesCreateRenameReorderDelete() {
        var b = QueueBook.initial()
        let id = b.createQueue(name: "  寝る前  ")!
        XCTAssertEqual(b.queues.map(\.name), ["メイン", "サブ", "寝る前"])
        XCTAssertNil(b.createQueue(name: "   "))
        b.rename(id, to: "夜")
        b.moveQueue(id, by: -1)
        XCTAssertEqual(b.queues.map(\.name), ["メイン", "夜", "サブ"])
        b.moveQueue(b.queues[0].id, by: -1) // 端では止まる
        XCTAssertEqual(b.queues.map(\.name), ["メイン", "夜", "サブ"])
        b.add(ep(9), to: id, atTop: false)
        b.deleteQueue(id)
        XCTAssertEqual(b.queues.map(\.name), ["メイン", "サブ"])
        XCTAssertFalse(b.contains(9))
        b.deleteQueue(b.queues[1].id)
        b.deleteQueue(b.queues[0].id) // 最後の1つは消えない
        XCTAssertEqual(b.queues.count, 1)
    }

    /// 聴き終えたら同じキューの先頭 → 空なら右隣のキューの先頭（空のキューは飛ばす）→ 最後まで空なら止まる
    func testFinishAdvancesWithinQueueThenToNeighbourThenStops() {
        var b = QueueBook.initial()
        let main = b.queues[0].id, sub = b.queues[1].id
        let third = b.createQueue(name: "三つ目")!
        b.add(ep(1), to: main, atTop: false)
        b.add(ep(2), to: main, atTop: false)
        b.add(ep(5), to: third, atTop: false)

        var next = b.finish(1, playingFrom: main)
        XCTAssertEqual(next?.episode.id, 2)
        XCTAssertEqual(next?.queue, main)
        XCTAssertEqual(ids(b, 0), [2])

        // メインが空になる → サブは空なので飛ばして三つ目の先頭へ
        next = b.finish(2, playingFrom: main)
        XCTAssertEqual(next?.episode.id, 5)
        XCTAssertEqual(next?.queue, third)

        // 最後のキューを聴き終えた → 止まる（左のキューへは戻らない）
        b.add(ep(7), to: main, atTop: false)
        next = b.finish(5, playingFrom: third)
        XCTAssertNil(next)
        XCTAssertEqual(ids(b, 0), [7])
        _ = sub
    }

    func testFinishFromMiddleGoesToHeadOfSameQueue() {
        var b = QueueBook.initial()
        let main = b.queues[0].id
        for i in 1...3 { b.add(ep(i), to: main, atTop: false) }
        let next = b.finish(2, playingFrom: main)
        XCTAssertEqual(next?.episode.id, 1)
        XCTAssertEqual(ids(b, 0), [1, 3])
    }

    /// キューに入っていない回（番組の一覧から直接再生）を聴き終えたら、最初のキューの先頭から
    func testFinishOutsideQueueStartsFromFirstQueue() {
        var b = QueueBook.initial()
        let sub = b.queues[1].id
        b.add(ep(4), to: sub, atTop: false)
        let next = b.finish(99, playingFrom: nil)
        XCTAssertEqual(next?.episode.id, 4)
        XCTAssertEqual(next?.queue, sub)
    }

    /// 再生中に別のキューへ移された回を聴き終えたら、移った先のキューから続ける
    func testFinishUsesCurrentLocation() {
        var b = QueueBook.initial()
        let main = b.queues[0].id, sub = b.queues[1].id
        b.add(ep(1), to: main, atTop: false)
        b.add(ep(2), to: main, atTop: false)
        b.add(ep(3), to: sub, atTop: false)
        b.add(ep(1), to: sub, atTop: true)
        let next = b.finish(1, playingFrom: main)
        XCTAssertEqual(next?.episode.id, 3)
    }

    func testAutoAddRespectsSettingWindowAndOrder() {
        var b = QueueBook.initial()
        let main = b.queues[0].id, sub = b.queues[1].id
        b.add(ep(1), to: main, atTop: false)
        let since = Date().addingTimeInterval(-7 * 86400)
        // 入れない
        XCTAssertEqual(b.autoAdd([ep(10)], setting: .off, since: since), 0)
        // 末尾へ（2026-11-24 から自動追加は末尾だけ）: 古い順に後ろへ。7日より古い回・もうある回は入れない
        let fresh = [ep(10, daysAgo: 2), ep(11, daysAgo: 1), ep(12, daysAgo: 30), ep(1)]
        XCTAssertEqual(b.autoAdd(fresh, setting: .queue(main), since: since), 2)
        XCTAssertEqual(ids(b, 0), [1, 10, 11])
        XCTAssertEqual(b.autoAdd([ep(20, daysAgo: 3), ep(21, daysAgo: 1)], setting: .queue(sub), since: since), 2)
        XCTAssertEqual(ids(b, 1), [20, 21])
        // 消えたキューへの設定は何もしない
        XCTAssertEqual(b.autoAdd([ep(30)], setting: .queue(UUID()), since: since), 0)
    }

    /// 2026-11-24 より前の「先頭へ」の設定は末尾として読む（atTop を読み捨てる）
    func testOldAtTopAutoAddDecodesAsQueueTail() throws {
        let id = UUID()
        let old = #"{"queue":{"_0":"\#(id.uuidString)","atTop":true}}"#
        XCTAssertEqual(try JSONDecoder().decode(AutoAdd.self, from: Data(old.utf8)), .queue(id))
        let oldOff = #"{"off":{}}"#
        XCTAssertEqual(try JSONDecoder().decode(AutoAdd.self, from: Data(oldOff.utf8)), .off)
        // 端末の状態ごと: 先頭への設定が末尾になり、ほかはそのまま
        var b = QueueBook.initial()
        let main = b.queues[0].id
        b.add(ep(1), to: main, atTop: false)
        let state = #"{"book":\#(String(decoding: try JSONEncoder().encode(b), as: UTF8.self)),"positions":{"1":12.5},"autoAdd":{"7":{"queue":{"_0":"\#(main.uuidString)","atTop":true}}},"watermarks":{"7":42},"speed":1.3,"allowCellular":false}"#
        let s = try JSONDecoder().decode(PodcastState.self, from: Data(state.utf8))
        XCTAssertEqual(s.autoAdd[7], .queue(main))
        XCTAssertEqual(s.positions[1], 12.5)
        XCTAssertEqual(s.watermarks[7], 42)
        XCTAssertEqual(s.book, b)
    }

    func testStateRoundTripsThroughJSON() throws {
        var s = PodcastState()
        s.book.add(ep(1), to: s.book.queues[1].id, atTop: false)
        s.positions[1] = 123.5
        s.autoAdd[7] = .queue(s.book.queues[0].id)
        s.watermarks[7] = 42
        s.speed = 1.3
        s.nowPlaying = ep(1)
        let back = try JSONDecoder().decode(PodcastState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testDurationLabels() {
        XCTAssertEqual(Duration.clock(3725), "1:02:05")
        XCTAssertEqual(Duration.clock(65), "1:05")
        XCTAssertEqual(Duration.label(3725), "1時間3分")
        XCTAssertEqual(Duration.label(2550), "43分")
        XCTAssertEqual(Duration.label(nil), "")
    }

    /// 無限スクロール: 末尾から5件以内の行が見えたら次のページ（2026-11-24）
    func testEpisodePagingNearEnd() {
        let list = (1...30).map { ep($0) }
        XCTAssertFalse(EpisodePaging.nearEnd(1, in: list))
        XCTAssertFalse(EpisodePaging.nearEnd(25, in: list))
        XCTAssertTrue(EpisodePaging.nearEnd(26, in: list))
        XCTAssertTrue(EpisodePaging.nearEnd(30, in: list))
        XCTAssertFalse(EpisodePaging.nearEnd(99, in: list))
        XCTAssertTrue(EpisodePaging.nearEnd(1, in: [ep(1)]))
        XCTAssertEqual(EpisodePaging.pageSize, 30)
    }
}
