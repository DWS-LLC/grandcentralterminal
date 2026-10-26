// Left-to-right tree layout: a pane sits one gap right of the pane that
// spawned it, and its children stack in a column beside it.
//
//        ┌─ build                 a parent is centered on its children's
//   web ─┼─ storybook             column; every subtree gets its own band
//        └─ e2e                   of height, so nothing overlaps and cables
//   hub ─── api ─┬─ tests         never need to cross.
//                └─ lint
//
// Panes with no cable are one-pane trees. Trees pack in rows (a shelf),
// wrapping at about 1.6x as wide as tall, so a dozen strangers do not
// become a tower. Siblings and trees keep their current top-to-bottom
// order, so a pane you put above another stays above it.
//
// Pure rect math, same as Spring: no AppKit, runs in the CLI. Deterministic:
// same panes in, same layout out. The centroid of the result stays where
// the input's was, so the camera keeps looking at the same neighborhood.

import Foundation

public enum TreeLayout {
    // Row width limit relative to the square root of the trees' total area.
    private static let rowAspect = 1.6
    // A column of children this tall pulls its parent this share of that
    // height away (cables climbing a steep S would not bundle), at most
    // `maxColumnGap`, never less than the gap.
    private static let columnShare = 0.5
    private static let maxColumnGap = 640.0

    // New rects for `rects` (same order). `parents[i]` is the index of the
    // pane that spawned pane i, nil for a root. A cycle is cut at its
    // first member in reading order.
    public static func place(_ rects: [Rect], parents: [Int?], gap: Double) -> [Rect] {
        guard rects.count >= 2, parents.count == rects.count else { return rects }

        let order = rects.indices.sorted { before(rects, $0, $1) }
        let kids = children(order, parents)

        var out = rects
        var trees = [Tree]()
        for root in kids.roots {
            var tree = Tree(root: root)
            tree.height = measure(root, rects, kids.of, gap, &tree.heights)
            tree.width = extent(root, rects, kids.of, gap, tree.heights)
            trees.append(tree)
        }

        let origins = shelf(trees, gap: gap)
        for (tree, at) in zip(trees, origins) {
            put(tree.root, x: at.x, top: at.y, rects, kids.of, gap, tree.heights, &out)
        }

        recenter(&out, like: rects)
        return out
    }

    // MARK: Order

    // Top first, then left to right: how you would read the canvas.
    private static func before(_ r: [Rect], _ a: Int, _ b: Int) -> Bool {
        let (ta, tb) = (r[a].y + r[a].h, r[b].y + r[b].h)
        if ta != tb { return ta > tb }
        if r[a].x != r[b].x { return r[a].x < r[b].x }
        return a < b
    }

    private struct Kids {
        var of: [Int: [Int]]
        var roots: [Int]
    }

    // Children lists in reading order, and the roots. Panes only reachable
    // through a cycle are rooted at their first member in reading order.
    private static func children(_ order: [Int], _ parents: [Int?]) -> Kids {
        var of = [Int: [Int]]()
        var roots = [Int]()
        for i in order {
            guard let p = parents[i], p != i, p >= 0, p < parents.count else {
                roots.append(i)
                continue
            }
            of[p, default: []].append(i)
        }

        var seen = Set<Int>()
        func visit(_ i: Int) {
            guard seen.insert(i).inserted else { return }
            for c in of[i] ?? [] { visit(c) }
        }
        for r in roots { visit(r) }

        for i in order where !seen.contains(i) {
            if let p = parents[i] { of[p]?.removeAll { $0 == i } }
            roots.append(i)
            visit(i)
        }
        return Kids(of: of, roots: roots)
    }

    // MARK: Measure

    private struct Tree {
        var root: Int
        var width = 0.0
        var height = 0.0
        var heights = [Int: Double]()    // band of every subtree
    }

    // Height of the band a subtree needs: its children's bands stacked, or
    // the pane itself if that is taller.
    @discardableResult
    private static func measure(_ i: Int, _ r: [Rect], _ kids: [Int: [Int]], _ gap: Double,
                                _ heights: inout [Int: Double]) -> Double {
        let sub = (kids[i] ?? []).map { measure($0, r, kids, gap, &heights) }
        let stack = sub.reduce(0, +) + gap * Double(max(sub.count - 1, 0))
        let band = max(r[i].h, stack)
        heights[i] = band
        return band
    }

    private static func extent(_ i: Int, _ r: [Rect], _ kids: [Int: [Int]], _ gap: Double,
                               _ heights: [Int: Double]) -> Double {
        let sub = kids[i] ?? []
        let deepest = sub.map { extent($0, r, kids, gap, heights) }.max() ?? 0
        guard deepest > 0 else { return r[i].w }
        return r[i].w + columnGap(sub, heights, gap) + deepest
    }

    // Room between a pane and the column of its children.
    private static func columnGap(_ sub: [Int], _ heights: [Int: Double], _ gap: Double) -> Double {
        let stack = sub.reduce(0) { $0 + (heights[$1] ?? 0) } + gap * Double(max(sub.count - 1, 0))
        return min(max(stack * columnShare, gap), max(maxColumnGap, gap))
    }

    // MARK: Place

    // Trees in rows, left to right, wrapping once a row passes the limit.
    // Returns each tree's top-left in y-down space.
    private static func shelf(_ trees: [Tree], gap: Double) -> [(x: Double, y: Double)] {
        let area = trees.reduce(0) { $0 + ($1.width + gap) * ($1.height + gap) }
        let limit = max(trees.map(\.width).max() ?? 0, area.squareRoot() * rowAspect)

        var out = [(x: Double, y: Double)]()
        var x = 0.0, y = 0.0, rowHeight = 0.0
        for t in trees {
            if x > 0, x + t.width > limit {
                x = 0
                y += rowHeight + gap
                rowHeight = 0
            }
            out.append((x, y))
            x += t.width + gap
            rowHeight = max(rowHeight, t.height)
        }
        return out
    }

    // Pane `i` centered in its band, its children in a column to the right,
    // centered on the band too. y is measured down from `top`.
    private static func put(_ i: Int, x: Double, top: Double, _ r: [Rect], _ kids: [Int: [Int]],
                            _ gap: Double, _ heights: [Int: Double], _ out: inout [Rect]) {
        let band = heights[i] ?? r[i].h
        let mid = top + band / 2
        out[i] = Rect(x: x, y: -(mid + r[i].h / 2), w: r[i].w, h: r[i].h)

        let sub = kids[i] ?? []
        let stack = sub.reduce(0) { $0 + (heights[$1] ?? 0) } + gap * Double(max(sub.count - 1, 0))
        var cursor = top + (band - stack) / 2
        let right = x + r[i].w + columnGap(sub, heights, gap)

        for c in sub {
            put(c, x: right, top: cursor, r, kids, gap, heights, &out)
            cursor += (heights[c] ?? 0) + gap
        }
    }

    // MARK: Recenter

    private static func recenter(_ rects: inout [Rect], like old: [Rect]) {
        let was = middle(old), now = middle(rects)
        for i in rects.indices {
            rects[i].x += was.x - now.x
            rects[i].y += was.y - now.y
        }
    }

    private static func middle(_ r: [Rect]) -> (x: Double, y: Double) {
        let minX = r.map(\.x).min() ?? 0, maxX = r.map { $0.x + $0.w }.max() ?? 0
        let minY = r.map(\.y).min() ?? 0, maxY = r.map { $0.y + $0.h }.max() ?? 0
        return ((minX + maxX) / 2, (minY + maxY) / 2)
    }
}
