import XCTest
@testable import Common

final class KeysTests: XCTestCase {
    // MARK: Notation

    func testStrokeParsing() {
        XCTAssertEqual(KeyStroke("cmd+shift+k")?.description, "cmd+shift+k")
        XCTAssertEqual(KeyStroke("Shift+Cmd+K")?.description, "cmd+shift+k")
        XCTAssertEqual(KeyStroke("control+option+return")?.description, "ctrl+alt+enter")
        XCTAssertEqual(KeyStroke("esc")?.description, "escape")
        XCTAssertEqual(KeyStroke("cmd++")?.description, "cmd++")
        XCTAssertEqual(KeyStroke("+")?.description, "+")
        XCTAssertEqual(KeyStroke("cmd+/")?.description, "cmd+/")
        XCTAssertEqual(KeyStroke("cmd+shift+1")?.description, "cmd+shift+1")
        XCTAssertEqual(KeyStroke("cmd+1")?.description, "cmd+1")
        XCTAssertNil(KeyStroke("cmd+"))
        XCTAssertNil(KeyStroke("hyper+a"))
        XCTAssertNil(KeyStroke("cmd+nonsense"))
        XCTAssertNil(KeyStroke(""))
    }

    func testSequenceParsing() {
        XCTAssertEqual(KeySequence("ctrl+b>c")?.strokes.count, 2)
        XCTAssertEqual(KeySequence("ctrl+x > ctrl+k > s")?.description, "ctrl+x>ctrl+k>s")
        XCTAssertNil(KeySequence("ctrl+b>"))
        XCTAssertNil(KeySequence(">c"))
        XCTAssertNil(KeySequence("a>b>c>d>e>f>g>h>i"))
    }

    func testAddressParsing() {
        XCTAssertEqual(KeyAddress("resize/left")?.mode, "resize")
        XCTAssertEqual(KeyAddress("resize/g>g")?.sequence.strokes.count, 2)
        XCTAssertNil(KeyAddress("cmd+/")?.mode)
        XCTAssertNil(KeyAddress("/")?.mode)
        XCTAssertEqual(KeyAddress("/")?.sequence.description, "/")
        XCTAssertNil(KeyAddress("Resize/left")?.mode)
        XCTAssertNil(KeyAddress("resize/"))
    }

    // MARK: Engine

    private func engine(_ entries: [(String, String)], modes: [String: Bool] = [:], token: String = "s") -> KeyEngine {
        let e = KeyEngine()
        e.replace(KeymapWire(token: token, entries: entries.enumerated().map {
            .init(serial: $0.offset, keys: $0.element.0, action: $0.element.1)
        }, modes: modes))
        return e
    }

    private func fired(_ o: KeyOutcome) -> String? {
        guard case .fire(let f) = o, case .action(let name, _) = f.target else { return nil }

        return name
    }

    func testSingleKey() {
        let e = engine([("cmd+d", "split")])
        XCTAssertEqual(fired(e.feed("cmd+d")), "split")
        XCTAssertEqual(e.feed("cmd+e"), .pass)
    }

    func testSequence() {
        let e = engine([("ctrl+b>c", "new"), ("ctrl+b>z", "zoom")])
        XCTAssertEqual(e.feed("ctrl+b"), .consumed)
        XCTAssertTrue(e.isPending)
        XCTAssertEqual(fired(e.feed("c")), "new")
        XCTAssertFalse(e.isPending)

        XCTAssertEqual(e.feed("ctrl+b"), .consumed)
        XCTAssertEqual(fired(e.feed("z")), "zoom")
    }

    func testSequencePrefixIsReported() {
        let e = engine([("ctrl+x>ctrl+k>s", "switch")])
        _ = e.feed("ctrl+x")
        _ = e.feed("ctrl+k")
        guard case .fire(let f) = e.feed("s") else { return XCTFail("no fire") }

        XCTAssertEqual(f.key.description, "s")
        XCTAssertEqual(f.prefix.map(\.description), ["ctrl+x", "ctrl+k"])
    }

    func testSequenceBreaksOnStrayKey() {
        let e = engine([("ctrl+b>c", "new")])
        _ = e.feed("ctrl+b")
        XCTAssertEqual(e.feed("q"), .consumed)
        XCTAssertFalse(e.isPending)
        XCTAssertEqual(e.feed("c"), .pass)
    }

    func testEscapeCancelsSequence() {
        let e = engine([("ctrl+b>c", "new")])
        _ = e.feed("ctrl+b")
        XCTAssertEqual(e.feed("escape"), .consumed)
        XCTAssertFalse(e.isPending)
        XCTAssertEqual(e.feed("c"), .pass)
    }

    func testCancelPendingDropsTheSequence() {
        let e = engine([("ctrl+b>c", "new")])
        _ = e.feed("ctrl+b")
        e.cancelPending()
        XCTAssertFalse(e.isPending)
        XCTAssertNil(e.status)
        XCTAssertEqual(e.feed("c"), .pass)
    }

    func testNewerBindingWinsConflict() {
        let e = KeyEngine()
        e.replace(KeymapWire(token: KeyEngine.configSource, entries: [.init(serial: 0, keys: "ctrl+b", action: "old")]))
        XCTAssertEqual(fired(e.feed("ctrl+b")), "old")

        // A sequence on the same key buries the single binding.
        e.replace(KeymapWire(token: "script", entries: [.init(serial: 0, keys: "ctrl+b>c", action: "seq")]))
        XCTAssertEqual(e.feed("ctrl+b"), .consumed)
        XCTAssertEqual(fired(e.feed("c")), "seq")

        // And it comes back when the script goes.
        e.remove(source: "script")
        XCTAssertEqual(fired(e.feed("ctrl+b")), "old")
    }

    func testLaterScriptBeatsEarlier() {
        let e = engine([("a", "first")], token: "one")
        e.replace(KeymapWire(token: "two", entries: [.init(serial: 0, keys: "a", action: "second")]))
        XCTAssertEqual(fired(e.feed("a")), "second")
    }

    func testBlockPassesTheKeyThrough() {
        let e = KeyEngine()
        e.replace(KeymapWire(token: KeyEngine.configSource, entries: [.init(serial: 0, keys: "cmd+t", action: "new-pane")]))
        e.replace(KeymapWire(token: "s", entries: [.init(serial: 0, keys: "cmd+t", block: true)]))
        XCTAssertEqual(e.feed("cmd+t"), .pass)

        // Bound again after the block: the binding wins.
        e.replace(KeymapWire(token: "s", entries: [
            .init(serial: 0, keys: "cmd+t", block: true),
            .init(serial: 1, keys: "cmd+t", action: "mine"),
        ]))
        XCTAssertEqual(fired(e.feed("cmd+t")), "mine")
    }

    // MARK: Modes

    private func resizeEngine(exclusive: Bool, once: Bool = false) -> KeyEngine {
        let e = KeyEngine()
        let args = "{\"name\":\"resize\"\(once ? ",\"once\":true" : "")}"
        e.replace(KeymapWire(token: "s", entries: [
            .init(serial: 0, keys: "cmd+r", action: "client.mode.enter", args: args),
            .init(serial: 1, keys: "resize/left", action: "grow-left"),
            .init(serial: 2, keys: "resize/enter", action: "client.mode.exit"),
            .init(serial: 3, keys: "x", action: "outside"),
        ], modes: ["resize": exclusive]))
        return e
    }

    func testModeEnterAndExit() {
        let e = resizeEngine(exclusive: false)
        XCTAssertEqual(e.feed("left"), .pass)
        XCTAssertEqual(e.feed("cmd+r"), .consumed)
        XCTAssertEqual(e.modeNames, ["resize"])
        XCTAssertEqual(fired(e.feed("left")), "grow-left")
        XCTAssertEqual(e.feed("enter"), .consumed)
        XCTAssertEqual(e.modeNames, [])
        XCTAssertEqual(e.feed("left"), .pass)
    }

    func testNonExclusiveModeFallsThrough() {
        let e = resizeEngine(exclusive: false)
        _ = e.feed("cmd+r")
        XCTAssertEqual(fired(e.feed("x")), "outside")
        XCTAssertEqual(e.feed("q"), .pass)
    }

    func testExclusiveModeSwallows() {
        let e = resizeEngine(exclusive: true)
        _ = e.feed("cmd+r")
        XCTAssertEqual(e.feed("x"), .consumed)
        XCTAssertEqual(e.feed("q"), .consumed)
        XCTAssertEqual(fired(e.feed("left")), "grow-left")
    }

    func testEscapeLeavesAMode() {
        let e = resizeEngine(exclusive: true)
        _ = e.feed("cmd+r")
        XCTAssertEqual(e.feed("escape"), .consumed)
        XCTAssertEqual(e.modeNames, [])
        XCTAssertEqual(fired(e.feed("x")), "outside")
    }

    func testModeCanBindEscape() {
        let e = KeyEngine()
        e.replace(KeymapWire(token: "s", entries: [
            .init(serial: 0, keys: "cmd+r", action: "client.mode.enter", args: "{\"name\":\"m\"}"),
            .init(serial: 1, keys: "m/escape", action: "mine"),
        ]))
        _ = e.feed("cmd+r")
        XCTAssertEqual(fired(e.feed("escape")), "mine")
        XCTAssertEqual(e.modeNames, ["m"])
    }

    func testOnceModeServesOneShortcut() {
        let e = resizeEngine(exclusive: true, once: true)
        _ = e.feed("cmd+r")
        XCTAssertEqual(fired(e.feed("left")), "grow-left")
        XCTAssertEqual(e.modeNames, [])
    }

    func testModeStackNewestFirst() {
        let e = KeyEngine()
        e.replace(KeymapWire(token: "s", entries: [
            .init(serial: 0, keys: "f1", action: "client.mode.enter", args: "{\"name\":\"a\"}"),
            .init(serial: 1, keys: "f2", action: "client.mode.enter", args: "{\"name\":\"b\"}"),
            .init(serial: 2, keys: "a/k", action: "from-a"),
            .init(serial: 3, keys: "b/k", action: "from-b"),
            .init(serial: 4, keys: "a/j", action: "a-only"),
            .init(serial: 5, keys: "f3", action: "client.mode.exit_all"),
        ]))
        _ = e.feed("f1")
        _ = e.feed("f2")
        XCTAssertEqual(e.modeNames, ["a", "b"])
        XCTAssertEqual(fired(e.feed("k")), "from-b")
        XCTAssertEqual(fired(e.feed("j")), "a-only")
        _ = e.feed("f3")
        XCTAssertEqual(e.modeNames, [])
    }

    func testSequenceInsideMode() {
        let e = KeyEngine()
        e.replace(KeymapWire(token: "s", entries: [
            .init(serial: 0, keys: "f1", action: "client.mode.enter", args: "{\"name\":\"nav\"}"),
            .init(serial: 1, keys: "nav/g>g", action: "top"),
        ], modes: ["nav": true]))
        _ = e.feed("f1")
        XCTAssertEqual(e.feed("g"), .consumed)
        XCTAssertEqual(fired(e.feed("g")), "top")
    }

    func testBlockedKeyInMode() {
        let e = KeyEngine()
        e.replace(KeymapWire(token: KeyEngine.configSource, entries: [.init(serial: 0, keys: "x", action: "outside")]))
        e.replace(KeymapWire(token: "s", entries: [
            .init(serial: 0, keys: "f1", action: "client.mode.enter", args: "{\"name\":\"m\"}"),
            .init(serial: 1, keys: "m/x", block: true),
        ]))
        _ = e.feed("f1")
        XCTAssertEqual(e.feed("x"), .pass)
        XCTAssertEqual(e.feed("escape"), .consumed)
        XCTAssertEqual(fired(e.feed("x")), "outside")
    }

    func testDroppingAScriptLeavesItsModes() {
        let e = resizeEngine(exclusive: true)
        _ = e.feed("cmd+r")
        e.remove(source: "s")
        XCTAssertEqual(e.modeNames, [])
        XCTAssertEqual(e.feed("q"), .pass)
    }

    func testEnteringAnUnknownModeDoesNothing() {
        let e = KeyEngine()
        e.replace(KeymapWire(token: "s", entries: [
            .init(serial: 0, keys: "f1", action: "client.mode.enter", args: "{\"name\":\"ghost\"}"),
        ]))
        XCTAssertEqual(e.feed("f1"), .consumed)
        XCTAssertEqual(e.modeNames, [])
    }

    func testStatusText() {
        let e = resizeEngine(exclusive: false)
        XCTAssertNil(e.status)
        _ = e.feed("cmd+r")
        XCTAssertEqual(e.status, "resize")
    }
}
