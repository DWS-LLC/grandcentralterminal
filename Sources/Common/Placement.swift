// Where `gctd open` asks for a pane, relative to the pane that calls it.
//
//            above
//          ┌────────┐
//   left   │ caller │   right      side= picks the edge the new pane
//          └────────┘              touches; size=33%,100% is a share of
//            below                 the caller's width and height.
//
// Flush against the caller: the daemon still resolves it against the live
// layout (window-gap, overlaps, group shoves), so this is only the ask.
//
// Pure rect math, same as Overlap: no AppKit, runs in the CLI.

import Foundation

public enum Side: String, CaseIterable, Sendable {
    case right, left, above, below
}

public struct Extent: Sendable, Equatable {
    public var w: Double
    public var h: Double
    public init(w: Double, h: Double) { self.w = w; self.h = h }
}

public enum SizeError: Error, Equatable {
    case malformed
    case needsCaller
}

public enum Placement {
    private static let percent: Character = "%"
    private static let percentScale = 100.0

    // "480,240" in world points, or "33%,100%" of `caller`. The two axes
    // may mix: "33%,240".
    public static func size(_ raw: String, caller: Rect?) throws -> Extent {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw SizeError.malformed }

        let w = try axis(parts[0], of: caller?.w)
        let h = try axis(parts[1], of: caller?.h)
        return Extent(w: w, h: h)
    }

    // `size` flush against `side` of `caller`. Left and right share the
    // caller's bottom edge, above and below its left edge (y grows up),
    // the same spots the open-new-window-* keybinds use.
    public static func beside(_ caller: Rect, side: Side, size: Extent) -> Rect {
        switch side {
        case .right: Rect(x: caller.x + caller.w, y: caller.y, w: size.w, h: size.h)
        case .left: Rect(x: caller.x - size.w, y: caller.y, w: size.w, h: size.h)
        case .above: Rect(x: caller.x, y: caller.y + caller.h, w: size.w, h: size.h)
        case .below: Rect(x: caller.x, y: caller.y - size.h, w: size.w, h: size.h)
        }
    }

    private static func axis(_ token: Substring, of reference: Double?) throws -> Double {
        let isShare = token.last == percent
        let number = isShare ? token.dropLast() : token
        guard let n = Double(number), n.isFinite, n > 0 else { throw SizeError.malformed }
        guard isShare else { return n }
        guard let reference else { throw SizeError.needsCaller }

        return reference * n / percentScale
    }
}
