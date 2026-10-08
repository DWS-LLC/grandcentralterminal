// Window-overlap geometry shared by the app (Canvas) and the daemon.
//
// Pure rect math over Common.Rect — no AppKit, no CoreGraphics — so the
// daemon can arbitrate layout: every movePane is resolved against the true
// store BEFORE broadcast, making the broadcast stream itself overlap-free.
// Clients keep a resolve pass as a no-op-safe fallback (idempotent on
// already-clean rects), and for local drags/resizes that never hit the
// daemon until mouse-up.
//
// All rects are world coordinates. Shared edges don't count as overlap:
// panes placed flush against a neighbor are legal, only area-positive
// intersection is a collision.

import Foundation

public enum Overlap {
    public static func overlaps(_ a: Rect, _ b: Rect) -> Bool {
        a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y
    }

    // Minimal translation that separates rect from obs: escape along the
    // axis of least penetration, biased to keep the push direction
    // (incoming motion) over bouncing perpendicular. A window shoved
    // horizontally into a same-size neighbor must exit sideways (past
    // it), not teleport above it: ties and near-ties go horizontal.
    public static func pushOut(_ rect: Rect, from obs: Rect) -> Rect {
        let cx1 = obs.x - (rect.x + rect.w), cx2 = (obs.x + obs.w) - rect.x
        let dx = abs(cx1) <= abs(cx2) ? cx1 : cx2
        let cy1 = obs.y - (rect.y + rect.h), cy2 = (obs.y + obs.h) - rect.y
        let dy = abs(cy1) <= abs(cy2) ? cy1 : cy2
        // Horizontal bias: a vertical escape needs a CLEAR margin
        // (quarter of the smaller height) to beat sideways.
        let margin = min(rect.h, obs.h) / 4
        if abs(dx) <= abs(dy) + margin {
            return Rect(x: rect.x + dx, y: rect.y, w: rect.w, h: rect.h)
        }
        return Rect(x: rect.x, y: rect.y + dy, w: rect.w, h: rect.h)
    }

    // Push rect out of every obstacle. Escaping one can enter another, so
    // iterate until stable; bounded by obstacle count. Pushes can
    // oscillate (rect straddling two neighbors bounces B->C->B), so on
    // failure fall back to directional placement: each axis jump strictly
    // advances past one blocker edge, which terminates on an infinite
    // canvas. Nearest of the four escapes wins. Guaranteed overlap-free.
    public static func resolve(_ rect: Rect, obstacles: [Rect]) -> Rect {
        let orig = rect
        var rect = rect
        for _ in 0...obstacles.count {
            var moved = false
            for obs in obstacles where overlaps(rect, obs) {
                rect = pushOut(rect, from: obs)
                moved = true
            }
            if !moved { return rect }
        }
        let cands = [
            resolve(orig, direction: 1, axis: .horizontal, obstacles: obstacles),
            resolve(orig, direction: -1, axis: .horizontal, obstacles: obstacles),
            resolve(orig, direction: 1, axis: .vertical, obstacles: obstacles),
            resolve(orig, direction: -1, axis: .vertical, obstacles: obstacles),
        ].filter { r in !obstacles.contains(where: { overlaps(r, $0) }) }
        return cands.min(by: {
            let dx0 = $0.x - orig.x, dy0 = $0.y - orig.y
            let dx1 = $1.x - orig.x, dy1 = $1.y - orig.y
            return dx0 * dx0 + dy0 * dy0 < dx1 * dx1 + dy1 * dy1
        }) ?? orig
    }

    public enum Axis { case horizontal, vertical }

    // Placement resolver: while rect hits an obstacle, jump past the
    // nearest blocker along ONE axis in one direction (`dir` = +1 or -1).
    public static func resolve(_ rect: Rect, direction dir: Int, axis: Axis,
                               obstacles: [Rect]) -> Rect {
        var rect = rect
        for _ in 0...obstacles.count {
            let hit: Rect? = obstacles.filter { overlaps(rect, $0) }.min {
                switch (axis, dir > 0) {
                case (.horizontal, true): $0.x + $0.w < $1.x + $1.w
                case (.horizontal, false): $0.x > $1.x
                case (.vertical, true): $0.y + $0.h < $1.y + $1.h
                case (.vertical, false): $0.y > $1.y
                }
            }
            guard let obs = hit else { return rect }
            switch (axis, dir > 0) {
            case (.horizontal, true): rect.x = obs.x + obs.w
            case (.horizontal, false): rect.x = obs.x - rect.w
            case (.vertical, true): rect.y = obs.y + obs.h
            case (.vertical, false): rect.y = obs.y - rect.h
            }
        }
        return rect
    }
    // Which edges a resize moves.
    public struct Edges {
        public var w = false, e = false, s = false, n = false
        public init(w: Bool = false, e: Bool = false,
                    s: Bool = false, n: Bool = false) {
            self.w = w; self.e = e; self.s = s; self.n = n
        }
    }

    public static func clampResize(_ candidate: Rect, original: Rect,
                                   edges: Edges, obstacles: [Rect]) -> Rect {
        var rect = candidate
        for obs in obstacles {
            guard overlaps(rect, obs), !overlaps(original, obs) else { continue }
            if edges.e, original.x + original.w <= obs.x {
                rect.w = max(0, obs.x - rect.x)
            }
            if edges.w, original.x >= obs.x + obs.w {
                let maxX = rect.x + rect.w
                rect.x = max(rect.x, obs.x + obs.w)
                rect.w = max(0, maxX - rect.x)
            }
            if edges.n, original.y + original.h <= obs.y {
                rect.h = max(0, obs.y - rect.y)
            }
            if edges.s, original.y >= obs.y + obs.h {
                let maxY = rect.y + rect.h
                rect.y = max(rect.y, obs.y + obs.h)
                rect.h = max(0, maxY - rect.y)
            }
        }
        return rect
    }

    // Shove-resize: `candidate` is the focused pane's grown rect (fixed);
    // blockers are pushed out of the way along ONE axis in `sign`
    // direction. Returns updated frames for `obstacles` in order.
    public static func pushForResize(_ candidate: Rect, obstacles: [Rect],
                                     axis: Axis, sign: Int) -> [Rect] {
        var frames = obstacles
        var moved = Set<Int>()
        let cap = (frames.count + 1) * (frames.count + 1) + 1
        for _ in 0..<cap {
            if let i = frames.firstIndex(where: { overlaps($0, candidate) }) {
                switch (axis, sign > 0) {
                case (.horizontal, true): frames[i].x = candidate.x + candidate.w
                case (.horizontal, false):
                    frames[i].x = candidate.x - frames[i].w
                case (.vertical, true): frames[i].y = candidate.y + candidate.h
                case (.vertical, false):
                    frames[i].y = candidate.y - frames[i].h
                }
                moved.insert(i)
                continue
            }
            var pair: (Int, Int)?
            for a in frames.indices {
                for b in frames.indices where b > a {
                    if overlaps(frames[a], frames[b]),
                       moved.contains(a) || moved.contains(b) {
                        pair = (a, b)
                        break
                    }
                }
                if pair != nil { break }
            }
            guard let (a, b) = pair else { return frames }
            let moveA: Bool = switch (axis, sign > 0) {
            case (.horizontal, true): frames[a].x > frames[b].x
            case (.horizontal, false): frames[a].x < frames[b].x
            case (.vertical, true): frames[a].y > frames[b].y
            case (.vertical, false): frames[a].y < frames[b].y
            }
            if moveA {
                switch (axis, sign > 0) {
                case (.horizontal, true): frames[a].x = frames[b].x + frames[b].w
                case (.horizontal, false):
                    frames[a].x = frames[b].x - frames[a].w
                case (.vertical, true): frames[a].y = frames[b].y + frames[b].h
                case (.vertical, false):
                    frames[a].y = frames[b].y - frames[a].h
                }
                moved.insert(a)
            } else {
                switch (axis, sign > 0) {
                case (.horizontal, true): frames[b].x = frames[a].x + frames[a].w
                case (.horizontal, false):
                    frames[b].x = frames[a].x - frames[b].w
                case (.vertical, true): frames[b].y = frames[a].y + frames[a].h
                case (.vertical, false):
                    frames[b].y = frames[a].y - frames[b].h
                }
                moved.insert(b)
            }
        }
        return frames
    }
}
