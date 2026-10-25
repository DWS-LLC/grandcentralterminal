// Directional focus with memory (cmd+h/j/k/l).
//
// Geometry alone is a function of the layout. Moving is a function of
// the layout AND where you just came from, so two rules sit on top:
//
//   back-edge   A -right-> B remembers B.left = A. Pressing left from B
//               returns to A, even when staggering makes C nearer.
//
//                  ┌───┐
//                  │ A │┌───┐     geometry from B going left says C
//                  └───┘│ B │     (smaller gap); the trail says A.
//                    ┌──┤   │
//                    │ C└───┘
//                    └──┘
//
//   goal line   a run of moves on one axis keeps the perpendicular
//               coordinate you started from (like vim's curswant), so
//               a column of equal-gap panes keeps you in your row.
//
// Memory only ever picks a pane that passes the same candidate test as
// every other pane, so it can't teleport. Any focus change that didn't
// come from here (click, switcher, hover, new pane) drops the history.

import AppKit
import Common

struct FocusTrail {
    enum Mode {
        case geometric
        case remembered
    }

    private enum Axis {
        case horizontal
        case vertical
    }

    private static let edgeSlack: CGFloat = 0.5

    private var back = [PaneID: [GCTNewWindowDirection: PaneID]]()
    private var landed: PaneID?
    private var goal: (axis: Axis, coord: CGFloat)?

    // Pane to focus when moving `dir` from `id`, or nil when nothing
    // lies that way. Records the hop so the opposite key can undo it.
    mutating func next(_ dir: GCTNewWindowDirection, from id: PaneID,
                       rects: [PaneID: CGRect], mode: Mode) -> PaneID? {
        guard let f = rects[id] else { return nil }

        if landed != id || mode == .geometric {
            reset()
        }
        back = back.filter { rects[$0.key] != nil }

        let axis = Self.axis(dir)
        let line = goal?.axis == axis ? goal!.coord : Self.center(f, axis)
        let target = remembered(dir, from: id, f, rects, line)
            ?? nearest(dir, f, rects, line, excluding: id)
        guard let target else { return nil }

        goal = (axis, line)
        landed = target
        back[target, default: [:]][Self.opposite(dir)] = id
        return target
    }

    private mutating func reset() {
        back = [:]
        goal = nil
    }

    private func remembered(_ dir: GCTNewWindowDirection, from id: PaneID, _ f: CGRect,
                            _ rects: [PaneID: CGRect], _ line: CGFloat) -> PaneID? {
        guard let id = back[id]?[dir], let r = rects[id] else { return nil }
        guard Self.reach(dir, f, r, line) != nil else { return nil }
        return id
    }

    private func nearest(_ dir: GCTNewWindowDirection, _ f: CGRect, _ rects: [PaneID: CGRect],
                         _ line: CGFloat, excluding id: PaneID) -> PaneID? {
        var best: (id: PaneID, gap: CGFloat, drift: CGFloat)?
        for (pid, r) in rects where pid != id {
            guard let hit = Self.reach(dir, f, r, line) else { continue }
            if let b = best, (hit.gap, hit.drift) >= (b.gap, b.drift) { continue }
            best = (pid, hit.gap, hit.drift)
        }
        return best?.id
    }

    // Gap between facing edges and drift from the goal line, or nil
    // when `r` isn't in that direction from `f`. Candidates must overlap
    // `f` on the perpendicular axis: only panes actually that way count.
    private static func reach(_ dir: GCTNewWindowDirection, _ f: CGRect, _ r: CGRect,
                              _ line: CGFloat) -> (gap: CGFloat, drift: CGFloat)? {
        switch dir {
        case .left:
            guard r.maxX <= f.minX + edgeSlack, r.maxY > f.minY, r.minY < f.maxY else { return nil }
            return (f.minX - r.maxX, abs(r.midY - line))
        case .right:
            guard r.minX >= f.maxX - edgeSlack, r.maxY > f.minY, r.minY < f.maxY else { return nil }
            return (r.minX - f.maxX, abs(r.midY - line))
        case .above:
            guard r.minY >= f.maxY - edgeSlack, r.maxX > f.minX, r.minX < f.maxX else { return nil }
            return (r.minY - f.maxY, abs(r.midX - line))
        case .below:
            guard r.maxY <= f.minY + edgeSlack, r.maxX > f.minX, r.minX < f.maxX else { return nil }
            return (f.minY - r.maxY, abs(r.midX - line))
        }
    }

    private static func axis(_ dir: GCTNewWindowDirection) -> Axis {
        switch dir {
        case .left, .right: return .horizontal
        case .above, .below: return .vertical
        }
    }

    // Perpendicular center: the y of a horizontal run, the x of a vertical one.
    private static func center(_ r: CGRect, _ axis: Axis) -> CGFloat {
        switch axis {
        case .horizontal: return r.midY
        case .vertical: return r.midX
        }
    }

    private static func opposite(_ dir: GCTNewWindowDirection) -> GCTNewWindowDirection {
        switch dir {
        case .left: return .right
        case .right: return .left
        case .above: return .below
        case .below: return .above
        }
    }
}
