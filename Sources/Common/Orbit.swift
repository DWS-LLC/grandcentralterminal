// Attract/repel placement for panes spawned by agents.
//
// The caller's pane is the "main" window: new panes are pulled toward it
// and pushed away from every other pane, so a spawn lands in the free
// air around main instead of wedged against a stranger.
//
//            . . . . . .
//         .   ┌──────┐   .      candidates sit on rings of growing
//        .    │ main │    .     radius around main (rect-shaped, so
//         .   └──────┘   .      corners clear it too); the lowest
//            . . . . . .        cost wins:
//                                 cost = distance to main
//                                      + repel from other panes
//
// Pure rect math, same as Overlap: no AppKit, runs in the CLI.

import Foundation

public enum Orbit {
    private static let angleSteps = 24
    private static let ringCount = 10
    private static let ringStep = 120.0
    // Others closer than this (edge to edge) push the candidate away.
    private static let repelRange = 400.0
    // Repel cost at zero clearance, in world points of "distance".
    private static let repelWeight = 300.0
    // Float noise must not reject a candidate sitting exactly `gap` away.
    private static let slack = 0.5

    // Best free spot of `size` around `main`, or nil when every
    // candidate collides (caller falls back to its own placement).
    // `obstacles` block; `others` (every pane but main) also repel.
    public static func place(size: Rect, around main: Rect, obstacles blocking: [Rect],
                             others: [Rect], gap: Double) -> Rect? {
        let obstacles = blocking + [main]
        let mainC = center(main)
        var best: (rect: Rect, cost: Double)?

        for ring in 0..<ringCount {
            for step in 0..<angleSteps {
                let theta = 2 * Double.pi * Double(step) / Double(angleSteps)
                let rect = candidate(size: size, main: main, theta: theta,
                                     extra: Double(ring) * ringStep, gap: gap)
                if obstacles.contains(where: { Overlap.overlaps(grown(rect, by: 2 * gap - slack), $0) }) {
                    continue
                }

                let c = center(rect)
                let pull = hypot(c.x - mainC.x, c.y - mainC.y)
                let push = others.reduce(0.0) { $0 + repel(rect, from: $1) }
                let cost = pull + push
                if let b = best, b.cost <= cost {
                    continue
                }
                best = (rect, cost)
            }
        }
        return best?.rect
    }

    // Point on the rect-shaped ring around main at angle theta, so a
    // candidate at any angle starts just clear of main (plus `extra`).
    private static func candidate(size: Rect, main: Rect, theta: Double,
                                  extra: Double, gap: Double) -> Rect {
        let a = (main.w + size.w) / 2 + gap + extra
        let b = (main.h + size.h) / 2 + gap + extra
        let dx = cos(theta), dy = sin(theta)
        let t = 1 / max(abs(dx) / a, abs(dy) / b)
        let c = center(main)
        return Rect(x: c.x + dx * t - size.w / 2, y: c.y + dy * t - size.h / 2,
                    w: size.w, h: size.h)
    }

    // Quadratic falloff: 0 at repelRange, repelWeight when touching.
    private static func repel(_ r: Rect, from o: Rect) -> Double {
        let dx = max(o.x - (r.x + r.w), r.x - (o.x + o.w), 0)
        let dy = max(o.y - (r.y + r.h), r.y - (o.y + o.h), 0)
        let near = 1 - min(hypot(dx, dy), repelRange) / repelRange
        return repelWeight * near * near
    }

    private static func center(_ r: Rect) -> (x: Double, y: Double) {
        (r.x + r.w / 2, r.y + r.h / 2)
    }

    private static func grown(_ r: Rect, by m: Double) -> Rect {
        Rect(x: r.x - m / 2, y: r.y - m / 2, w: r.w + m, h: r.h + m)
    }
}
