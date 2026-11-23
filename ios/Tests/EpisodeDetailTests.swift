import XCTest
@testable import Tayori

/// 回の詳細ページ（2026-11-24）: 概要の HTML → 読みやすい文字・取っ手で並べ替えたあとの並び・聴き終えた回・古い保存データの読み込み
final class EpisodeDetailTests: XCTestCase {
    private func ep(_ id: Int, daysAgo: Double = 0) -> Episode {
        let iso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-daysAgo * 86400))
        return Episode(id: id, feedId: 1, feedTitle: "番組", feedImageUrl: nil, title: "回\(id)", url: nil,
                       publishedAt: iso, sortAt: iso, enclosureUrl: "https://cdn.example/\(id).mp3", enclosureType: "audio/mpeg", durationSec: 600)
    }

    // MARK: - 概要

    func testNotesParagraphsBreaksAndLists() {
        let html = "<p>一段落目</p><p>二段落目<br>改行<br/>もう一行</p><ul><li>あ</li><li>い</li></ul><ol><li>一</li><li>二</li></ol><p>おわり</p>"
        XCTAssertEqual(ShowNotes.plain(fromHTML: html), "一段落目\n\n二段落目\n改行\nもう一行\n\n・あ\n・い\n\n1. 一\n2. 二\n\nおわり")
    }

    func testNotesDropScriptStyleImagesAndComments() {
        let html = "<p>前<img src=\"https://e.example/x.png\" alt=\"画像\">後</p><script>alert('x')</script><style>p{color:red}</style><!-- メモ --><iframe src=\"https://e.example\">中</iframe><p>残る</p>"
        let s = ShowNotes.plain(fromHTML: html)
        XCTAssertEqual(s, "前後\n\n残る")
        XCTAssertFalse(s.contains("alert"))
    }

    func testNotesLinksAndEntities() {
        let a = ShowNotes.attributed(fromHTML: "<p>詳しくは <a href=\"https://ex.example/a?x=1&amp;y=2\">こちら</a> &amp; &#x1F3A7; &hellip;</p><p><a href=\"javascript:alert(1)\">だめ</a></p>")
        XCTAssertEqual(String(a.characters), "詳しくは こちら & 🎧 …\n\nだめ")
        let links = a.runs.compactMap { r -> (String, URL)? in r.link.map { (String(a[r.range].characters), $0) } }
        XCTAssertEqual(links.count, 1, "http(s) だけをリンクに")
        XCTAssertEqual(links.first?.0, "こちら")
        XCTAssertEqual(links.first?.1.absoluteString, "https://ex.example/a?x=1&y=2")
    }

    func testNotesPlainTextKeepsNewlinesAndLinksBareURLs() {
        let a = ShowNotes.attributed(fromHTML: "一行目\n二行目 https://rebuild.fm/436/ へ")
        XCTAssertEqual(String(a.characters), "一行目\n二行目 https://rebuild.fm/436/ へ")
        XCTAssertEqual(a.runs.compactMap(\.link).first?.absoluteString, "https://rebuild.fm/436/")
    }

    func testNotesEmptyAndTruncatedTag() {
        XCTAssertEqual(ShowNotes.plain(fromHTML: ""), "")
        XCTAssertEqual(ShowNotes.plain(fromHTML: "<p>  </p><br><br>"), "")
        XCTAssertEqual(ShowNotes.plain(fromHTML: "<p>切れた<a hre"), "切れた")
    }

    // MARK: - 取っ手で並べ替え

    func testReorderFollowsIds() {
        var b = QueueBook.initial()
        let q = b.queues[0].id
        for i in 1...4 { b.add(ep(i), to: q, atTop: false) }
        b.reorder(in: q, to: [3, 1, 2, 4])
        XCTAssertEqual(b.queue(q)!.episodes.map(\.id), [3, 1, 2, 4])
        // 知らない id は無視・並びに無い回は末尾に残す
        b.reorder(in: q, to: [4, 99, 3])
        XCTAssertEqual(b.queue(q)!.episodes.map(\.id), [4, 3, 1, 2])
    }

    // MARK: - 聴き終えた

    func testAutoAddSkipsPlayedEpisodes() {
        var b = QueueBook.initial()
        let q = b.queues[0].id
        let n = b.autoAdd([ep(1), ep(2), ep(3)], setting: .queue(q), since: Date().addingTimeInterval(-86400 * 7), skipping: [2])
        XCTAssertEqual(n, 2)
        XCTAssertEqual(b.queue(q)!.episodes.map(\.id), [1, 3])
    }

    /// played の無い 2026-11-24 より前の保存データも、キュー・位置・速度を失わずに読める
    func testOldStateWithoutPlayedDecodes() throws {
        var s = PodcastState()
        s.book.add(ep(1), to: s.book.queues[0].id, atTop: false)
        s.positions[1] = 42
        s.speed = 1.5
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        obj.removeValue(forKey: "played")
        let old = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(PodcastState.self, from: old)
        XCTAssertEqual(back.book, s.book)
        XCTAssertEqual(back.positions, [1: 42])
        XCTAssertEqual(back.speed, 1.5)
        XCTAssertEqual(back.played, [:])
        // played つきで書いて読み直しても同じ
        var p = back
        p.played[7] = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(try JSONDecoder().decode(PodcastState.self, from: JSONEncoder().encode(p)), p)
    }

    func testFullDate() {
        XCTAssertEqual(When.fullDate(nil), "")
        XCTAssertTrue(When.fullDate("2026-11-24T03:00:00.000Z").hasPrefix("2026年11月"))
    }
}
