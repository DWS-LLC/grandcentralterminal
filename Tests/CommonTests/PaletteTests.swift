import XCTest
@testable import Common

final class PaletteTests: XCTestCase {
    private let items = [
        PaletteText(title: "Leaf: Open Document…", category: "Leaf", keywords: "pdf markdown read"),
        PaletteText(title: "Leaf: Review Diff", category: "Leaf", keywords: "git changes"),
        PaletteText(title: "Fit All", category: "GCT", detail: "zoom out to every pane"),
        PaletteText(title: "Notes", category: "Docs", keywords: "leaf notes"),
    ]

    private func titles(_ query: String) -> [String] {
        PaletteRank.order(items, query: query).map { items[$0].title }
    }

    func testEmptyQueryKeepsEverythingInOrder() {
        XCTAssertEqual(PaletteRank.order(items, query: ""), [0, 1, 2, 3])
        XCTAssertEqual(PaletteRank.order(items, query: "   "), [0, 1, 2, 3])
    }

    func testEveryWordHasToFit() {
        XCTAssertEqual(titles("leaf open"), ["Leaf: Open Document…"])
        XCTAssertEqual(titles("open leaf"), ["Leaf: Open Document…"])
        XCTAssertEqual(titles("leaf zebra"), [])
    }

    func testTitleBeatsCategoryBeatsKeywordsBeatsDetail() {
        // "leaf": two titles lead with it, then a keyword hit.
        XCTAssertEqual(titles("leaf"), ["Leaf: Open Document…", "Leaf: Review Diff", "Notes"])
        XCTAssertEqual(titles("pane"), ["Fit All"])
        XCTAssertEqual(titles("git"), ["Leaf: Review Diff"])
    }

    func testAWordOfTheTitleCountsAsAPrefix() {
        XCTAssertEqual(titles("doc").first, "Leaf: Open Document…")
        XCTAssertEqual(titles("diff"), ["Leaf: Review Diff"])
    }

    func testLettersInOrderAreAFallback() {
        XCTAssertEqual(titles("lod"), ["Leaf: Open Document…"])
        XCTAssertEqual(titles("dol"), [])
    }

    func testTiesKeepTheirOrder() {
        let same = [PaletteText(title: "Alpha"), PaletteText(title: "Alpha too"), PaletteText(title: "Alpha again")]
        XCTAssertEqual(PaletteRank.order(same, query: "alpha"), [0, 1, 2])
    }

    func testWireRoundTrip() throws {
        let wire = PaletteWire(token: "t", entries: [
            .init(name: "open", title: "Open", description: "d", category: "c", keywords: "k"),
            .init(name: "bare", title: "Bare"),
        ])
        let back = try JSONDecoder().decode(PaletteWire.self, from: JSONEncoder().encode(wire))
        XCTAssertEqual(back.token, "t")
        XCTAssertEqual(back.entries, wire.entries)
        XCTAssertTrue(PaletteWire(token: "t").isEmpty)

        let cmd = CanvasCommand(verb: .palette, palette: wire)
        let relayed = try JSONDecoder().decode(CanvasCommand.self, from: JSONEncoder().encode(cmd))
        XCTAssertEqual(relayed.verb, .palette)
        XCTAssertEqual(relayed.palette?.entries.count, 2)
    }
}
