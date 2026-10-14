// Arrange engine: pure packing math for "Arrange By" (no UI, no config).
//
// Layout space has its origin top-left with y growing DOWN, and the
// caller maps it onto the canvas (y-up). Output frames come back in input
// order, so sorting is the caller's job.
//
//   rows      a b c        columns   a d
//             d e                    b e
//                                    c
//   grid      a b c   (table: column widths / row heights follow
//             d e f    the widest / tallest unit in each)

import Foundation

public enum ArrangeShape: String, CaseIterable, Sendable {
    case rows, columns, grid
}

public struct ArrangeSize: Sendable, Equatable {
    public var w: Double
    public var h: Double
    public init(w: Double, h: Double) { self.w = w; self.h = h }
}

public enum ArrangeEngine {
    /// Frames for `sizes` in layout space. `limit` is the extent rows wrap
    /// at (width) and columns wrap at (height); grids ignore its absolute
    /// size and only use its aspect ratio to pick a column count.
    public static func pack(_ sizes: [ArrangeSize], shape: ArrangeShape,
                            limit: ArrangeSize, gap: Double) -> [Rect] {
        guard !sizes.isEmpty else { return [] }
        switch shape {
        case .rows: return shelf(sizes, limit: limit.w, gap: gap)
        case .columns: return transpose(shelf(sizes.map { ArrangeSize(w: $0.h, h: $0.w) },
                                              limit: limit.h, gap: gap))
        case .grid: return table(sizes, aspect: limit.w / max(limit.h, 1), gap: gap)
        }
    }

    /// Union of frames; nil when empty.
    public static func bounds(_ frames: [Rect]) -> Rect? {
        guard let first = frames.first else { return nil }
        var minX = first.x, minY = first.y
        var maxX = first.x + first.w, maxY = first.y + first.h
        for f in frames.dropFirst() {
            minX = min(minX, f.x)
            minY = min(minY, f.y)
            maxX = max(maxX, f.x + f.w)
            maxY = max(maxY, f.y + f.h)
        }
        return Rect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    /// Typical size of a set (median per axis): one giant pane must not
    /// inflate every cell of a normalized grid.
    public static func median(_ sizes: [ArrangeSize]) -> ArrangeSize? {
        guard !sizes.isEmpty else { return nil }
        let ws = sizes.map(\.w).sorted()
        let hs = sizes.map(\.h).sorted()
        let mid = ws.count / 2
        return ArrangeSize(w: ws[mid], h: hs[mid])
    }

    // Left to right, wrapping when the next unit would cross `limit`.
    // A shelf is as tall as its tallest unit; units hang from its top.
    private static func shelf(_ sizes: [ArrangeSize], limit: Double,
                              gap: Double) -> [Rect] {
        var out = [Rect]()
        var x = 0.0, y = 0.0, shelfH = 0.0
        for s in sizes {
            if x > 0, x + s.w > limit {
                x = 0
                y += shelfH + gap
                shelfH = 0
            }
            out.append(Rect(x: x, y: y, w: s.w, h: s.h))
            x += s.w + gap
            shelfH = max(shelfH, s.h)
        }
        return out
    }

    private static func transpose(_ frames: [Rect]) -> [Rect] {
        frames.map { Rect(x: $0.y, y: $0.x, w: $0.h, h: $0.w) }
    }

    // Column count that makes the whole table match `aspect` (w/h).
    private static func table(_ sizes: [ArrangeSize], aspect: Double,
                              gap: Double) -> [Rect] {
        let n = Double(sizes.count)
        let meanW = sizes.map(\.w).reduce(0, +) / n
        let meanH = sizes.map(\.h).reduce(0, +) / n
        let ideal = (n * aspect * meanH / max(meanW, 1)).squareRoot()
        let cols = min(sizes.count, max(1, Int(ideal.rounded())))
        let rows = (sizes.count + cols - 1) / cols

        var colW = [Double](repeating: 0, count: cols)
        var rowH = [Double](repeating: 0, count: rows)
        for (i, s) in sizes.enumerated() {
            colW[i % cols] = max(colW[i % cols], s.w)
            rowH[i / cols] = max(rowH[i / cols], s.h)
        }

        var out = [Rect]()
        for (i, s) in sizes.enumerated() {
            let x = colW[..<(i % cols)].reduce(0) { $0 + $1 + gap }
            let y = rowH[..<(i / cols)].reduce(0) { $0 + $1 + gap }
            out.append(Rect(x: x, y: y, w: s.w, h: s.h))
        }
        return out
    }
}
