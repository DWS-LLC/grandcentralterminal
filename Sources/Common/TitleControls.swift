// Window controls in a pane's titlebar, like a macOS window's traffic lights.
//
//   ┌──────────────────────────────────────────────────┐
//   │  ●  ●  ●  ⋯   >_ claude  Spotter weather    ◐ 3s  │
//   │  │  │  │  └ menu                                  │
//   │  │  │  └ zoom     the title starts at `width`      │
//   │  │  └ float                                       │
//   │  └ close                                          │
//   └──────────────────────────────────────────────────┘
//
// Pure geometry in titlebar coordinates (origin bottom-left, y up): no
// AppKit, so it is tested without a canvas. Everything scales with the bar,
// which grows with the title font.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum TitleControl: CaseIterable, Sendable {
    case close, float, zoom, menu
}

public struct TitleControlsLayout: Sendable {
    // Measured off a macOS window: a 35pt bar holds 12pt dots 8pt apart,
    // 13pt in from the edge.
    private static let baseBarHeight: CGFloat = 35
    private static let baseDot: CGFloat = 12
    private static let baseGap: CGFloat = 8
    private static let baseInset: CGFloat = 13

    public let barHeight: CGFloat

    public init(barHeight: CGFloat) {
        self.barHeight = barHeight
    }

    private var scale: CGFloat { max(1, barHeight / Self.baseBarHeight) }
    private var dot: CGFloat { Self.baseDot * scale }
    private var gap: CGFloat { Self.baseGap * scale }
    private var inset: CGFloat { Self.baseInset * scale }

    /// Where the dot of `control` sits.
    public func frame(of control: TitleControl) -> CGRect {
        let slot = CGFloat(TitleControl.allCases.firstIndex(of: control) ?? 0)
        let pitch: CGFloat = dot + gap
        let x: CGFloat = inset + slot * pitch
        let y: CGFloat = (barHeight - dot) / 2
        return CGRect(x: x, y: y, width: dot, height: dot)
    }

    /// The cluster as a whole: hovering anywhere in it shows every glyph.
    public var cluster: CGRect {
        let last = frame(of: .menu)
        return CGRect(x: 0, y: 0, width: last.maxX + gap, height: barHeight)
    }

    /// How far from the left edge whatever follows the controls starts.
    public var width: CGFloat { cluster.maxX }

    /// The control under `point`. Each target reaches half a gap past its
    /// dot, so the gaps between dots are not dead and a near miss still hits.
    public func hit(_ point: CGPoint) -> TitleControl? {
        let slop = gap / 2
        return TitleControl.allCases.first {
            frame(of: $0).insetBy(dx: -slop, dy: -slop).contains(point)
        }
    }
}
