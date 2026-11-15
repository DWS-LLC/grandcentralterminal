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

    // MARK: Arguments

    func testSpecReadsRexSpelling() {
        XCTAssertEqual(PaletteArg(name: "n", spec: "string"), PaletteArg(name: "n", kind: .text))
        XCTAssertEqual(PaletteArg(name: "n", spec: "string?"), PaletteArg(name: "n", kind: .text, optional: true))
        XCTAssertEqual(PaletteArg(name: "n", spec: "Integer").kind, .integer)
        XCTAssertEqual(PaletteArg(name: "n", spec: "int?").kind, .integer)
        XCTAssertEqual(PaletteArg(name: "n", spec: "float").kind, .number)
        XCTAssertEqual(PaletteArg(name: "n", spec: "bool").kind, .boolean)
        // Not ours: text, so a Rex script still loads.
        XCTAssertEqual(PaletteArg(name: "n", spec: "path").kind, .text)
        XCTAssertTrue(PaletteArg(name: "n", spec: "path?").optional)
    }

    func testAnswersAreTyped() {
        let text = PaletteArg(name: "t", kind: .text)
        XCTAssertEqual(text.value(of: " hi there "), .text(" hi there "))

        let whole = PaletteArg(name: "i", kind: .integer)
        XCTAssertEqual(whole.value(of: "42"), .integer(42))
        XCTAssertEqual(whole.value(of: " -7 "), .integer(-7))
        XCTAssertNil(whole.value(of: "4.5"))
        XCTAssertNil(whole.value(of: "x"))

        let number = PaletteArg(name: "n", kind: .number)
        XCTAssertEqual(number.value(of: "4.5"), .number(4.5))
        XCTAssertEqual(number.value(of: "3"), .number(3))
        XCTAssertNil(number.value(of: "nan"))
        XCTAssertNil(number.value(of: "inf"))
        XCTAssertNil(number.value(of: ""))

        let flag = PaletteArg(name: "b", kind: .boolean)
        for yes in ["true", "Yes", " y ", "ON", "1"] { XCTAssertEqual(flag.value(of: yes), .boolean(true), yes) }
        for no in ["false", "NO", "n", "off", "0"] { XCTAssertEqual(flag.value(of: no), .boolean(false), no) }
        XCTAssertNil(flag.value(of: "maybe"))
    }

    func testValuesAreJSON() throws {
        let values: [PaletteArg.Value] = [.text("a"), .number(1.5), .integer(3), .boolean(true)]
        let data = try JSONSerialization.data(
            withJSONObject: ["t": values[0].json, "n": values[1].json, "i": values[2].json, "b": values[3].json],
            options: [.sortedKeys])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"b":true,"i":3,"n":1.5,"t":"a"}"#)
    }

    func testEntryCarriesItsArgsOnTheWire() throws {
        let entry = PaletteWire.Entry(name: "open", title: "Open", args: [
            PaletteArg(name: "count", kind: .integer),
            PaletteArg(name: "note", kind: .text, optional: true),
        ])
        let back = try JSONDecoder().decode(PaletteWire.Entry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(back, entry)

        // An entry from before args existed has none.
        let old = try JSONDecoder().decode(PaletteWire.Entry.self, from: Data(#"{"name":"a","title":"A"}"#.utf8))
        XCTAssertNil(old.args)
    }
}
