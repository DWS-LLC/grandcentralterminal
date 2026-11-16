import XCTest
@testable import Common

final class RecencyTests: XCTestCase {
    func testTouchMovesToTheFront() {
        var r = Recency(keys: ["a", "b", "c"])
        r.touch("c")
        XCTAssertEqual(r.keys, ["c", "a", "b"])
        r.touch("z")
        XCTAssertEqual(r.keys, ["z", "c", "a", "b"])
    }

    func testForgetAndLimit() {
        var r = Recency<String>(limit: 2)
        r.touch("a"); r.touch("b"); r.touch("c")
        XCTAssertEqual(r.keys, ["c", "b"])
        r.forget("c")
        XCTAssertEqual(r.keys, ["b"])
    }

    func testSeenFirstNewestFirstThenTheRestInOrder() {
        var r = Recency<String>()
        r.touch("b"); r.touch("d")
        XCTAssertEqual(r.sorted(["a", "b", "c", "d", "e"], by: { $0 }), ["d", "b", "a", "c", "e"])
    }

    func testNothingSeenKeepsOrder() {
        let r = Recency<String>()
        XCTAssertEqual(r.sorted(["x", "y", "z"], by: { $0 }), ["x", "y", "z"])
    }
}
