// Max-zoom camera for a set of pane rects around a keep-out hole.
//
// Fitting the bounding box into the biggest strip beside the hole wastes
// the bbox's empty corners. Panes only need to clear the hole themselves:
//
//   strip fit (bbox clear)          packed fit (panes clear)
//   ┌─────┬────────────────┐       ┌─────┬──────────────────┐
//   │ PiP │                │       │ PiP │ ┌──────┐ ┌─────┐ │
//   ├─────┘ ┌────┐ ┌─────┐ │       ├─────┘ │      │ │     │ │
//   │       │    │ │     │ │  ──►  │ ┌────┐│      │ │     │ │
//   │       └────┘ └─────┘ │       │ │    │└──────┘ └─────┘ │
//   └──────────────────────┘       └─┴────┴─────────────────┘
//
// For a given zoom, each pane forbids a rect of camera offsets (those
// that land it on the hole). Free offsets are the area minus those rects,
// so a free offset always exists at a rect edge or the preferred center.

import CoreGraphics

enum FitSolver {
    private static let steps = 24
    private static let edgeSlack: CGFloat = 0.001

    // Largest-zoom camera keeping every pane (world rects) inside `area`
    // and clear of `keepOut` (both view coords), centered as far as the
    // hole allows. Nil when not even the smallest zoom fits.
    static func fit(_ rects: [CGRect], in area: CGRect, keepOut: CGRect,
                    scales: ClosedRange<CGFloat>) -> Camera? {
        let bbox = rects.reduce(CGRect.null) { $0.union($1) }
        guard !bbox.isNull, bbox.width > 0, bbox.height > 0 else { return nil }

        let ceiling = min(area.width / bbox.width, area.height / bbox.height,
                          scales.upperBound)
        guard ceiling >= scales.lowerBound else { return nil }

        if let cam = place(rects, bbox, area, keepOut, ceiling) {
            return cam
        }

        // Bisect: the biggest zoom that still finds a free offset.
        var low = scales.lowerBound
        var high = ceiling
        var best: Camera?
        for _ in 0..<steps {
            let mid = (low + high) / 2
            guard let cam = place(rects, bbox, area, keepOut, mid) else {
                high = mid
                continue
            }
            best = cam
            low = mid
        }
        return best
    }

    // The free offset nearest the centered one at `scale`, or nil.
    private static func place(_ rects: [CGRect], _ bbox: CGRect, _ area: CGRect,
                              _ keepOut: CGRect, _ scale: CGFloat) -> Camera? {
        let xs = span(area.minX - bbox.minX * scale, area.maxX - bbox.maxX * scale)
        let ys = span(area.minY - bbox.minY * scale, area.maxY - bbox.maxY * scale)
        let center = CGPoint(x: area.midX - bbox.midX * scale,
                             y: area.midY - bbox.midY * scale)

        let banned = rects.map { r in
            CGRect(x: keepOut.minX - r.maxX * scale,
                   y: keepOut.minY - r.maxY * scale,
                   width: keepOut.width + r.width * scale,
                   height: keepOut.height + r.height * scale)
        }

        let xEdges = candidates(banned.flatMap { [$0.minX, $0.maxX] }, center.x, xs)
        let yEdges = candidates(banned.flatMap { [$0.minY, $0.maxY] }, center.y, ys)

        var best: CGPoint?
        var bestDist = CGFloat.infinity
        for x in xEdges {
            for y in yEdges {
                let p = CGPoint(x: x, y: y)
                let dist = hypot(x - center.x, y - center.y)
                guard dist < bestDist, !banned.contains(where: { inside(p, $0) }) else { continue }
                best = p
                bestDist = dist
            }
        }
        return best.map { Camera(offset: $0, scale: scale) }
    }

    // Float noise can flip a bound pair at the exact ceiling zoom.
    private static func span(_ a: CGFloat, _ b: CGFloat) -> ClosedRange<CGFloat> {
        min(a, b)...max(a, b)
    }

    // Edge values plus the preferred one, clamped into `range`.
    private static func candidates(_ edges: [CGFloat], _ preferred: CGFloat,
                                   _ range: ClosedRange<CGFloat>) -> [CGFloat] {
        (edges + [preferred, range.lowerBound, range.upperBound])
            .map { min(max($0, range.lowerBound), range.upperBound) }
    }

    // Strictly inside: touching an edge is clear.
    private static func inside(_ p: CGPoint, _ r: CGRect) -> Bool {
        p.x > r.minX + edgeSlack && p.x < r.maxX - edgeSlack
            && p.y > r.minY + edgeSlack && p.y < r.maxY - edgeSlack
    }
}
