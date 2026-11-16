import XCTest
@testable import Common

final class CommandGroupsTests: XCTestCase {
    private let a = PaneID()
    private let b = PaneID()
    private let c = PaneID()

    func testAssignThenRecall() {
        var g = CommandGroups()
        g.assign(1, owner: "local", ids: [a, b])
        XCTAssertEqual(g.recall(1), .init(owner: "local", ids: [a, b]))
        XCTAssertNil(g.recall(2))
    }

    func testAssignReplaces() {
        var g = CommandGroups()
        g.assign(1, owner: "local", ids: [a])
        g.assign(1, owner: "enterprise", ids: [c])
        XCTAssertEqual(g.recall(1), .init(owner: "enterprise", ids: [c]))
    }

    func testEmptyAssignKeepsTheSlot() {
        var g = CommandGroups()
        g.assign(1, owner: "local", ids: [a])
        g.assign(1, owner: "local", ids: [])
        XCTAssertEqual(g.recall(1), .init(owner: "local", ids: [a]))
    }

    func testForgetShrinksThenEmpties() {
        var g = CommandGroups()
        g.assign(1, owner: "local", ids: [a, b])
        g.assign(2, owner: "local", ids: [b])
        g.forget(b)
        XCTAssertEqual(g.recall(1), .init(owner: "local", ids: [a]))
        XCTAssertNil(g.recall(2))
        g.forget(a)
        XCTAssertNil(g.recall(1))
    }

    func testSlotsHoldingAPane() {
        var g = CommandGroups()
        g.assign(3, owner: "local", ids: [a])
        g.assign(1, owner: "local", ids: [a, b])
        XCTAssertEqual(g.slots(holding: a), [1, 3])
        XCTAssertEqual(g.slots(holding: b), [1])
        XCTAssertEqual(g.slots(holding: c), [])
    }
}
