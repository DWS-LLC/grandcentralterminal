// Window-overlap geometry: pure CGRect math, no AppKit, so it compiles
// and tests standalone. All rects are world coordinates (y-up).

import CoreGraphics

// Shared edges don't count as overlap: panes placed flush against a
// neighbor are legal, only area-positive intersection is a collision.
enum Overlap {
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && a.maxX > b.minX && a.minY < b.maxY && a.maxY > b.minY
    }

    // Minimal translation along one axis that separates rect from obs
    // (AABB depenetration): push past whichever of the obstacle's edges is
    // nearest, on whichever axis needs less movement.
    static func pushOut(_ rect: CGRect, from obs: CGRect) -> CGRect {
        let dx = abs(obs.minX - rect.maxX) <= abs(obs.maxX - rect.minX)
            ? obs.minX - rect.maxX : obs.maxX - rect.minX
        let dy = abs(obs.minY - rect.maxY) <= abs(obs.maxY - rect.minY)
            ? obs.minY - rect.maxY : obs.maxY - rect.minY
        return abs(dx) <= abs(dy)
            ? rect.offsetBy(dx: dx, dy: 0)
            : rect.offsetBy(dx: 0, dy: dy)
    }

    // Push rect out of every obstacle. Escaping one can enter another, so
    // iterate until stable; bounded by obstacle count (each pass strictly
    // exits at least one obstacle, and re-entry of a passed one is
    // impossible along the push axis). Best effort with the cap.
    static func resolve(_ rect: CGRect, obstacles: [CGRect]) -> CGRect {
        var rect = rect
        for _ in 0...obstacles.count {
            var moved = false
            for obs in obstacles where overlaps(rect, obs) {
                rect = pushOut(rect, from: obs)
                moved = true
            }
            if !moved { return rect }
        }
        return rect
    }

    enum Axis { case horizontal, vertical }

    // Placement resolver: while rect hits an obstacle, jump past the
    // nearest blocker along ONE axis in one direction (`dir` = +1 or -1) —
    // a pane told to open right escapes rightward, never sideways. Each
    // jump strictly passes one obstacle along that axis, so this is
    // bounded by the obstacle count.
    static func resolve(_ rect: CGRect, direction dir: Int, axis: Axis,
                        obstacles: [CGRect]) -> CGRect {
        var rect = rect
        for _ in 0...obstacles.count {
            let hit = obstacles.filter { overlaps(rect, $0) }.min {
                switch (axis, dir > 0) {
                case (.horizontal, true):  $0.maxX < $1.maxX
                case (.horizontal, false): $0.minX > $1.minX
                case (.vertical, true):    $0.maxY < $1.maxY
                case (.vertical, false):   $0.minY > $1.minY
                }
            }
            guard let obs = hit else { return rect }
            switch (axis, dir > 0) {
            case (.horizontal, true):  rect.origin.x = obs.maxX
            case (.horizontal, false): rect.origin.x = obs.minX - rect.width
            case (.vertical, true):    rect.origin.y = obs.maxY
            case (.vertical, false):   rect.origin.y = obs.minY - rect.height
            }
        }
        return rect
    }

    // Which edges a resize moves.
    struct Edges {
        var w = false, e = false, s = false, n = false
    }

    // Clamp a resized rect so it never NEWLY overlaps an obstacle: an edge
    // clamps only when the overlap along that edge's axis is new (the
    // original rect was clear of the obstacle along it), so an edge always
    // stops at the obstacle's near side and pre-existing overlaps are left
    // for a move to untangle.
    static func clampResize(_ candidate: CGRect, original: CGRect,
                            edges: Edges, obstacles: [CGRect]) -> CGRect {
        var rect = candidate
        for obs in obstacles {
            guard overlaps(rect, obs), !overlaps(original, obs) else { continue }
            if edges.e, original.maxX <= obs.minX {
                rect.size.width = min(rect.maxX, obs.minX) - rect.minX
            }
            if edges.w, original.minX >= obs.maxX {
                let x = max(rect.minX, obs.maxX)
                rect.size.width = rect.maxX - x
                rect.origin.x = x
            }
            if edges.n, original.maxY <= obs.minY {
                rect.size.height = min(rect.maxY, obs.minY) - rect.minY
            }
            if edges.s, original.minY >= obs.maxY {
                let y = max(rect.minY, obs.maxY)
                rect.size.height = rect.maxY - y
                rect.origin.y = y
            }
        }
        return rect
    }
    // Shove-resize: `candidate` is the focused pane's grown rect (fixed);
    // blockers are pushed out of the way along ONE axis in `sign`
    // direction (+1 = east/north, -1 = west/south). Direct blockers land
    // flush past the candidate's edge; panes they collide with chain
    // along in the same direction. Every move is strictly monotonic
    // along the push axis (a cleared pane only moves further away), so
    // this terminates; the cap is a best-effort backstop. Sizes never
    // change, only origins.
    static func pushForResize(_ candidate: CGRect, obstacles: [CGRect],
                              axis: Axis, sign: Int) -> [CGRect] {
        var frames = obstacles
        var moved = Set<Int>()
        let cap = (frames.count + 1) * (frames.count + 1) + 1
        for _ in 0..<cap {
            // Direct blockers first: flush past the candidate's edge.
            if let i = frames.firstIndex(where: { overlaps($0, candidate) }) {
                switch (axis, sign > 0) {
                case (.horizontal, true): frames[i].origin.x = candidate.maxX
                case (.horizontal, false):
                    frames[i].origin.x = candidate.minX - frames[i].width
                case (.vertical, true): frames[i].origin.y = candidate.maxY
                case (.vertical, false):
                    frames[i].origin.y = candidate.minY - frames[i].height
                }
                moved.insert(i)
                continue
            }
            // Chains: an overlap involving a moved pane pushes the
            // further-along pane past its neighbor, same direction.
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
            case (.horizontal, true): frames[a].minX > frames[b].minX
            case (.horizontal, false): frames[a].minX < frames[b].minX
            case (.vertical, true): frames[a].minY > frames[b].minY
            case (.vertical, false): frames[a].minY < frames[b].minY
            }
            if moveA {
                switch (axis, sign > 0) {
                case (.horizontal, true): frames[a].origin.x = frames[b].maxX
                case (.horizontal, false):
                    frames[a].origin.x = frames[b].minX - frames[a].width
                case (.vertical, true): frames[a].origin.y = frames[b].maxY
                case (.vertical, false):
                    frames[a].origin.y = frames[b].minY - frames[a].height
                }
                moved.insert(a)
            } else {
                switch (axis, sign > 0) {
                case (.horizontal, true): frames[b].origin.x = frames[a].maxX
                case (.horizontal, false):
                    frames[b].origin.x = frames[a].minX - frames[b].width
                case (.vertical, true): frames[b].origin.y = frames[a].maxY
                case (.vertical, false):
                    frames[b].origin.y = frames[a].minY - frames[b].height
                }
                moved.insert(b)
            }
        }
        return frames
    }
}
