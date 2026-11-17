import XCTest
@testable import Common

final class TitleControlsTests: XCTestCase {
    private let bar = TitleControlsLayout(barHeight: 35)

    func testControlsRunLeftToRightWithoutOverlap() {
        let frames = TitleControl.allCases.map { bar.frame(of: $0) }
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThan(a.maxX, b.minX)
        }
        XCTAssertEqual(TitleControl.allCases, [.close, .float, .zoom, .menu])
    }

    func testDotsAreCenteredInTheBar() {
        for control in TitleControl.allCases {
            XCTAssertEqual(bar.frame(of: control).midY, 35 / 2, accuracy: 0.001)
        }
    }

    func testTitleStartsPastTheCluster() {
        XCTAssertGreaterThan(bar.width, bar.frame(of: .menu).maxX)
        XCTAssertEqual(bar.width, bar.cluster.maxX)
    }

    func testHitFindsTheDotUnderThePoint() {
        for control in TitleControl.allCases {
            let f = bar.frame(of: control)
            XCTAssertEqual(bar.hit(CGPoint(x: f.midX, y: f.midY)), control)
        }
    }

    func testGapBetweenDotsStillHits() {
        let close = bar.frame(of: .close)
        let float = bar.frame(of: .float)
        let gapMid = CGPoint(x: (close.maxX + float.minX) / 2, y: close.midY)
        XCTAssertNotNil(bar.hit(gapMid))
    }

    func testMissesOutsideTheClusterAndFarAbove() {
        XCTAssertNil(bar.hit(CGPoint(x: bar.width + 40, y: 17)))
        XCTAssertNil(bar.hit(CGPoint(x: bar.frame(of: .close).midX, y: 35)))
        XCTAssertNil(bar.hit(CGPoint(x: bar.frame(of: .close).midX, y: 0)))
    }

    func testEverythingScalesWithTheBar() {
        let big = TitleControlsLayout(barHeight: 70)
        XCTAssertEqual(big.frame(of: .zoom).width, bar.frame(of: .zoom).width * 2, accuracy: 0.001)
        XCTAssertEqual(big.width, bar.width * 2, accuracy: 0.001)
    }

    func testASmallerBarKeepsTheBaseSize() {
        let small = TitleControlsLayout(barHeight: 20)
        XCTAssertEqual(small.frame(of: .zoom).width, bar.frame(of: .zoom).width, accuracy: 0.001)
    }
}

final class AppBundleTests: XCTestCase {
    func testBundleAroundAMacOSBinary() {
        XCTAssertEqual(AppBundle.root(of: "/Applications/Docker.app/Contents/MacOS/docker"),
                       "/Applications/Docker.app")
    }

    func testCaskBinaryDeepInsideTheBundle() {
        let exe = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        XCTAssertEqual(AppBundle.root(of: exe), "/Applications/Visual Studio Code.app")
    }

    func testOutermostWinsOverANestedHelper() {
        let exe = "/Applications/Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/helper"
        XCTAssertEqual(AppBundle.root(of: exe), "/Applications/Chrome.app")
    }

    func testPlainBinariesHaveNone() {
        XCTAssertNil(AppBundle.root(of: "/opt/homebrew/bin/nvim"))
        XCTAssertNil(AppBundle.root(of: "/usr/bin/zsh"))
    }

    func testNeedsAnAbsolutePathAndARealName() {
        XCTAssertNil(AppBundle.root(of: "Docker.app/Contents/MacOS/docker"))
        XCTAssertNil(AppBundle.root(of: "/tmp/.app/x"))
    }
}
