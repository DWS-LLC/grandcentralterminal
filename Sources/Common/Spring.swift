// Spring layout: related panes pull together, strangers push apart.
//
//        link            unrelated pair
//     ┌───┐ ←──→ ┌───┐     ┌───┐ ←── push ──→ ┌───┐
//     │ a │      │ b │     │ c │              │ d │
//     └───┘      └───┘     └───┘              └───┘
//
//   spring   linked bodies are pulled until their edges are `gap` apart
//            (rest length is edge to edge, not center to center), and
//            nudged into the same row or column so stacks come out square
//   repel    unlinked bodies push off each other inside `repelRange`
//   overlap  any pair closer than `gap` is shoved apart, linked or not
//
// Deterministic by construction: a fixed number of fixed-size steps from
// the bodies' current spots, index order everywhere, no randomness (the
// one degenerate case, coincident centers, picks its direction from the
// indices). So the same canvas relaxes the same way every time. It starts
// from where panes are, so related clusters tighten and strangers drift
// to `repelRange` apart instead of being re-rolled from scratch.
//
// Pure rect math, same as Orbit and Overlap: no AppKit, runs in the CLI.

import Foundation

public enum Spring {
    public struct Link: Sendable {
        public var a: Int
        public var b: Int
        public var weight: Double
        public init(a: Int, b: Int, weight: Double) {
            self.a = a; self.b = b; self.weight = weight
        }
    }

    private static let steps = 300
    // Pull per step, per point of edge gap, per unit of link weight.
    private static let stiffness = 0.08
    // Push at zero clearance, in points per step; falls off to 0 at range.
    private static let repelForce = 40.0
    private static let repelRange = 300.0
    // Share of the off-axis offset a link removes per step (row/column snap).
    private static let alignment = 0.04
    // Overlap is corrected by this share of its depth per step.
    private static let overlapShare = 0.5
    // No body moves further than this in one step.
    private static let maxStep = 60.0
    // Step size decays to this share of itself, so the end is a settle.
    private static let coolTo = 0.1
    private static let separatePasses = 60
    private static let epsilon = 1e-6
    // Golden angle: spreads coincident centers without any randomness.
    private static let goldenAngle = 2.399963229728653

    // New rects for `rects` (same order). `fixed` bodies never move but
    // still repel and block. The centroid of the movers stays put, so the
    // camera keeps looking at the same neighborhood.
    public static func relax(_ rects: [Rect], links: [Link], fixed: [Rect] = [],
                             gap: Double) -> [Rect] {
        guard rects.count >= 2 || (!rects.isEmpty && !fixed.isEmpty) else { return rects }

        var pos = rects.map(center)
        let size = rects.map { (w: $0.w, h: $0.h) }
        let fixedPos = fixed.map(center)
        let fixedSize = fixed.map { (w: $0.w, h: $0.h) }

        var linked = [Int: [Int: Double]]()
        for l in links where l.a != l.b && l.weight > 0 {
            linked[l.a, default: [:]][l.b, default: 0] += l.weight
            linked[l.b, default: [:]][l.a, default: 0] += l.weight
        }

        for step in 0..<steps {
            let cool = 1 - (1 - coolTo) * Double(step) / Double(steps)
            var move = [(x: Double, y: Double)](repeating: (0, 0), count: pos.count)

            for i in pos.indices {
                for j in pos.indices where j != i {
                    let f = force(from: i, to: j, at: pos[i], toward: pos[j],
                                  sizes: (size[i], size[j]), weight: linked[i]?[j],
                                  gap: gap)
                    move[i].x += f.x
                    move[i].y += f.y
                }
                for j in fixedPos.indices {
                    let f = force(from: i, to: pos.count + j, at: pos[i], toward: fixedPos[j],
                                  sizes: (size[i], fixedSize[j]), weight: nil, gap: gap)
                    move[i].x += f.x
                    move[i].y += f.y
                }
            }

            for i in pos.indices {
                let len = hypot(move[i].x, move[i].y) * cool
                guard len > epsilon else { continue }
                let scale = min(len, maxStep) / len * cool
                pos[i].x += move[i].x * scale
                pos[i].y += move[i].y * scale
            }
        }

        var out = zip(pos, size).map { Rect(x: $0.x - $1.w / 2, y: $0.y - $1.h / 2, w: $1.w, h: $1.h) }
        separate(&out, fixed: fixed, gap: gap)
        recenter(&out, like: rects)
        return out
    }

    // MARK: Forces

    // Force on body `i` from body `j`: positive pulls i toward j.
    private static func force(from i: Int, to j: Int, at p: (x: Double, y: Double),
                              toward q: (x: Double, y: Double),
                              sizes: ((w: Double, h: Double), (w: Double, h: Double)),
                              weight: Double?, gap: Double) -> (x: Double, y: Double) {
        var dx = q.x - p.x
        var dy = q.y - p.y
        var dist = hypot(dx, dy)

        if dist < epsilon {
            let angle = Double(i * 31 + j) * goldenAngle
            dx = cos(angle)
            dy = sin(angle)
            dist = 1
        }

        let ux = dx / dist, uy = dy / dist
        let edge = dist - touching(ux, uy, sizes.0, sizes.1, gap)

        // Overlap, or closer than the gap: shove apart, links included.
        if edge < 0 {
            let push = -edge * overlapShare
            return (-ux * push, -uy * push)
        }

        if let weight {
            let pull = stiffness * weight * edge
            let square = square(dx, dy, sizes: sizes, gap: gap, strength: alignment * weight)
            return (ux * pull + square.x, uy * pull + square.y)
        }

        guard edge < repelRange else { return (0, 0) }
        let near = 1 - edge / repelRange
        let push = repelForce * near * near
        return (-ux * push, -uy * push)
    }

    // Pull on the axis a linked pair is NOT stacked along, toward lining
    // their centers up: side by side snaps to one row, stacked to one column.
    private static func square(_ dx: Double, _ dy: Double,
                               sizes: ((w: Double, h: Double), (w: Double, h: Double)),
                               gap: Double, strength: Double) -> (x: Double, y: Double) {
        let hw = (sizes.0.w + sizes.1.w) / 2 + gap
        let hh = (sizes.0.h + sizes.1.h) / 2 + gap

        if abs(dx) / hw >= abs(dy) / hh {
            return (0, dy * strength)
        }
        return (dx * strength, 0)
    }

    // Center distance at which two rects, seen along unit vector (ux, uy),
    // sit exactly `gap` apart edge to edge.
    private static func touching(_ ux: Double, _ uy: Double,
                                 _ a: (w: Double, h: Double), _ b: (w: Double, h: Double),
                                 _ gap: Double) -> Double {
        let hw = (a.w + b.w) / 2 + gap
        let hh = (a.h + b.h) / 2 + gap
        return 1 / max(abs(ux) / hw, abs(uy) / hh, epsilon)
    }

    // MARK: Cleanup

    // Soft forces settle near-touching, not strictly clear. Push every
    // pair still inside the gap apart along the shallower axis.
    private static func separate(_ rects: inout [Rect], fixed: [Rect], gap: Double) {
        for _ in 0..<separatePasses {
            var clean = true

            for i in rects.indices {
                for j in rects.indices where j > i {
                    guard let (dx, dy) = depth(rects[i], rects[j], gap: gap) else { continue }
                    clean = false
                    rects[i].x -= dx / 2; rects[i].y -= dy / 2
                    rects[j].x += dx / 2; rects[j].y += dy / 2
                }

                for f in fixed {
                    guard let (dx, dy) = depth(rects[i], f, gap: gap) else { continue }
                    clean = false
                    rects[i].x -= dx; rects[i].y -= dy
                }
            }
            if clean { return }
        }
    }

    // Shove (dx, dy) moving `b` away from `a` along the shallower axis, or
    // nil when they are at least `gap` apart.
    private static func depth(_ a: Rect, _ b: Rect, gap: Double) -> (Double, Double)? {
        let ox = min(a.x + a.w, b.x + b.w) - max(a.x, b.x) + gap
        let oy = min(a.y + a.h, b.y + b.h) - max(a.y, b.y) + gap
        guard ox > 0, oy > 0 else { return nil }

        if ox < oy {
            return (b.x + b.w / 2 >= a.x + a.w / 2 ? ox : -ox, 0)
        }
        return (0, b.y + b.h / 2 >= a.y + a.h / 2 ? oy : -oy)
    }

    private static func recenter(_ rects: inout [Rect], like old: [Rect]) {
        guard !rects.isEmpty else { return }
        let was = centroid(old), now = centroid(rects)
        let dx = was.x - now.x, dy = was.y - now.y

        for i in rects.indices {
            rects[i].x += dx
            rects[i].y += dy
        }
    }

    private static func centroid(_ rects: [Rect]) -> (x: Double, y: Double) {
        let n = Double(rects.count)
        let sum = rects.map(center).reduce((x: 0.0, y: 0.0)) { ($0.x + $1.x, $0.y + $1.y) }
        return (sum.x / n, sum.y / n)
    }

    private static func center(_ r: Rect) -> (x: Double, y: Double) {
        (r.x + r.w / 2, r.y + r.h / 2)
    }
}

// How strongly two panes belong together: a cable (one spawned the other)
// ties them, nothing else does. The canvas folds these into per-unit links
// (a group moves as one block).
public enum SpringRelation {
    private static let cable = 2.0
    // A unit pair's weight never exceeds this: a 30-pane group must not
    // yank a stranger harder than a direct parent does.
    private static let cap = 3.0
    // Each extra cable between two blocks adds this much over the first.
    private static let extraCable = 0.1

    public static func weight(_ a: PaneMeta, _ b: PaneMeta) -> Double {
        a.parent == b.id || b.parent == a.id ? cable : 0
    }

    // Link weight between two blocks of panes.
    public static func weight(_ a: [PaneMeta], _ b: [PaneMeta]) -> Double {
        var cables = 0

        for x in a {
            for y in b where weight(x, y) > 0 { cables += 1 }
        }
        guard cables > 0 else { return 0 }
        return min(cap, cable + extraCable * Double(cables - 1))
    }
}
