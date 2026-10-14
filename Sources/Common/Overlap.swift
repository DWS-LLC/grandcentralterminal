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
        resolve(rect, obstacles: obstacles, gap: 0)
    }

    // Gap-aware resolve: keeps at least `gap` world points of air
    // between rect and every obstacle (gap <= 0 = legacy flush).
    // Inflates obstacles by half the gap and the mover by the other
    // half, resolves flush, then shrinks the mover back: flush
    // landings end up exactly `gap` apart, and zero-gap callers see
    // byte-identical behavior.
    public static func resolve(_ rect: Rect, obstacles: [Rect], gap: Double) -> Rect {
        guard gap > 0, !obstacles.isEmpty else {
            return resolveNoGap(rect, obstacles: obstacles)
        }
        // Half-gap each side: obstacle inflation + mover inflation sum
        // to the full gap, so flush inflated landings deflate to
        // exactly `gap` apart. Position-only: sizes restore after.
        let h = gap / 2
        let big = Rect(x: rect.x - h, y: rect.y - h, w: rect.w + gap, h: rect.h + gap)
        let fat = obstacles.map {
            Rect(x: $0.x - h, y: $0.y - h, w: $0.w + gap, h: $0.h + gap)
        }
        let clean = resolveNoGap(big, obstacles: fat)
        return Rect(x: clean.x + h, y: clean.y + h, w: rect.w, h: rect.h)
    }

    private static func resolveNoGap(_ rect: Rect, obstacles: [Rect]) -> Rect {
        // Canonical order: callers build obstacle lists from Swift dicts
        // (random per-process seed), so canvas and daemon would otherwise
        // resolve the same scene differently. Sort once at entry.
        let obstacles = obstacles.sorted {
            if $0.x != $1.x { return $0.x < $1.x }
            if $0.y != $1.y { return $0.y < $1.y }
            if $0.w != $1.w { return $0.w < $1.w }
            return $0.h < $1.h
        }
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
                                   edges: Edges, obstacles: [Rect], gap: Double = 0) -> Rect {
        var rect = candidate
        for obs in obstacles {
            guard overlaps(rect, obs), !overlaps(original, obs) else { continue }
            if edges.e, original.x + original.w <= obs.x {
                rect.w = max(0, obs.x - gap - rect.x)
            }
            if edges.w, original.x >= obs.x + obs.w {
                let maxX = rect.x + rect.w
                rect.x = max(rect.x, obs.x + obs.w + gap)
                rect.w = max(0, maxX - rect.x)
            }
            if edges.n, original.y + original.h <= obs.y {
                rect.h = max(0, obs.y - gap - rect.y)
            }
            if edges.s, original.y >= obs.y + obs.h {
                let maxY = rect.y + rect.h
                rect.y = max(rect.y, obs.y + obs.h + gap)
                rect.h = max(0, maxY - rect.y)
            }
        }
        return rect
    }

    // Shove-resize: `candidate` is the focused pane's grown rect (fixed);
    // blockers are pushed out of the way along ONE axis in `sign`
    // direction. Returns updated frames for `obstacles` in order. `gap`
    // keeps pushed frames that far off the candidate and each other.
    public static func pushForResize(_ candidate: Rect, obstacles: [Rect],
                                     axis: Axis, sign: Int, gap: Double = 0) -> [Rect] {
        // Deterministic across processes (see resolve): work on a
        // canonically sorted copy, then map back to input positions so
        // the return stays positional for zip-back callers.
        let order = obstacles.indices.sorted {
            let a = obstacles[$0], b = obstacles[$1]
            if a.x != b.x { return a.x < b.x }
            if a.y != b.y { return a.y < b.y }
            if a.w != b.w { return a.w < b.w }
            if a.h != b.h { return a.h < b.h }
            return $0 < $1
        }
        var frames = order.map { obstacles[$0] }
        var moved = Set<Int>()
        let cap = (frames.count + 1) * (frames.count + 1) + 1
        for _ in 0..<cap {
            if let i = frames.firstIndex(where: { overlaps($0, candidate) }) {
                switch (axis, sign > 0) {
                case (.horizontal, true): frames[i].x = candidate.x + candidate.w + gap
                case (.horizontal, false):
                    frames[i].x = candidate.x - frames[i].w - gap
                case (.vertical, true): frames[i].y = candidate.y + candidate.h + gap
                case (.vertical, false):
                    frames[i].y = candidate.y - frames[i].h - gap
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
            guard let (a, b) = pair else { return unmap(frames, order) }
            let moveA: Bool = switch (axis, sign > 0) {
            case (.horizontal, true): frames[a].x > frames[b].x
            case (.horizontal, false): frames[a].x < frames[b].x
            case (.vertical, true): frames[a].y > frames[b].y
            case (.vertical, false): frames[a].y < frames[b].y
            }
            if moveA {
                switch (axis, sign > 0) {
                case (.horizontal, true): frames[a].x = frames[b].x + frames[b].w + gap
                case (.horizontal, false):
                    frames[a].x = frames[b].x - frames[a].w - gap
                case (.vertical, true): frames[a].y = frames[b].y + frames[b].h + gap
                case (.vertical, false):
                    frames[a].y = frames[b].y - frames[a].h - gap
                }
                moved.insert(a)
            } else {
                switch (axis, sign > 0) {
                case (.horizontal, true): frames[b].x = frames[a].x + frames[a].w + gap
                case (.horizontal, false):
                    frames[b].x = frames[a].x - frames[b].w - gap
                case (.vertical, true): frames[b].y = frames[a].y + frames[a].h + gap
                case (.vertical, false):
                    frames[b].y = frames[a].y - frames[b].h - gap
                }
                moved.insert(b)
            }
        }
        return unmap(frames, order)
    }

    // Inverse of the canonical sort in pushForResize: sorted position i
    // holds input position order[i].
    private static func unmap(_ frames: [Rect], _ order: [Int]) -> [Rect] {
        var out = frames
        for (sorted, input) in order.enumerated() { out[input] = frames[sorted] }
        return out
    }
}

// MARK: - Terminal groups
// The group's exclusion rectangle is the union bounds of its member
// frames (plus padding), computed identically by daemon and canvas so
// neither side drifts. Panes outside the group always resolve against
// this rectangle, regardless of allowOverlap.
public enum GroupGeometry {
    // Padding in world points around the member union.
    public static let padding: Double = 16
    // Extra headroom above the topmost member for the group titlebar.
    // Matches the pane titlebar height so the family reads as one.
    public static let titleClearance: Double = 22

    // Union bounds of members + padding (+ title clearance on top). Nil
    // when fewer than one member frame is present (group hidden).
    public static func bounds(frames: [Rect]) -> Rect? {
        guard !frames.isEmpty else { return nil }
        var minX = frames[0].x, minY = frames[0].y
        var maxX = frames[0].x + frames[0].w
        var maxY = frames[0].y + frames[0].h
        for f in frames.dropFirst() {
            minX = min(minX, f.x)
            minY = min(minY, f.y)
            maxX = max(maxX, f.x + f.w)
            maxY = max(maxY, f.y + f.h)
        }
        return Rect(x: minX - padding, y: minY - padding,
                    w: maxX - minX + padding * 2,
                    h: maxY - minY + padding * 2 + titleClearance)
    }

    // Obstacles for a pane OUTSIDE the given membership: the bounds of
    // every group the pane is not in. Members ignore their own group's
    // bounds (they may touch/overlap freely); other groups still block.
    public static func obstacles(memberOf: Set<GroupID>,
                                 groups: [GroupID: (members: Set<PaneID>, bounds: Rect?)])
        -> [Rect] {
        var out = [Rect]()
        for (id, g) in groups where !memberOf.contains(id) {
            if let b = g.bounds { out.append(b) }
        }
        return out
    }

    // Rigid block move: shift the whole member set by (dx, dy), resolving
    // the GROUP BOUNDS against outside obstacles so relative offsets
    // survive. Returns nil when the shifted bounds already clear
    // everything (fast path); else the corrected origin delta.
    public static func resolveBlockMove(bounds: Rect,
                                        dx: Double, dy: Double,
                                        obstacles: [Rect]) -> (dx: Double, dy: Double)? {
        let target = Rect(x: bounds.x + dx, y: bounds.y + dy,
                          w: bounds.w, h: bounds.h)
        let clean = Overlap.resolve(target, obstacles: obstacles)
        guard clean.x != target.x || clean.y != target.y else { return nil }
        return (clean.x - bounds.x, clean.y - bounds.y)
    }
}
// MARK: - Group layout arbitration (shared canvas + daemon)
// Single source of truth so local drags and daemon arbitration agree.
// Rule: panes outside a group can never overlap its bounds, regardless
// of allowOverlap. Inside a group the normal overlap policy applies.
public enum GroupLayout {
    // Live bounds of every group with at least one known member frame.
    public static func bounds(groups: [GroupID: GroupMeta],
                              panes: [PaneID: Rect]) -> [GroupID: Rect] {
        var out = [GroupID: Rect]()
        for (id, g) in groups {
            let frames = g.members.compactMap { panes[$0] }
            if let b = GroupGeometry.bounds(frames: frames) { out[id] = b }
        }
        return out
    }
    // Group admission, shared by canvas (pre-check) and daemon (verdict):
    // may `id` join `gid` after `members`? Yes when the grown bounds stay
    // clear of foreign groups and of panes that aren't joining. `joining`
    // panes are leaving their donor groups, so donors are measured
    // without them (else moving a pane between adjacent groups would
    // always clash with the border it is about to leave).
    public static func admits(_ id: PaneID, into gid: GroupID,
                              members: [PaneID], joining: Set<PaneID>,
                              groups: [GroupID: GroupMeta],
                              panes: [PaneID: Rect]) -> Bool {
        var trialGroups = groups
        trialGroups[gid] = GroupMeta(id: gid, members: members + [id])
        guard let grown = bounds(groups: trialGroups, panes: panes)[gid] else {
            return true
        }

        var donors = groups
        donors.removeValue(forKey: gid)
        for (did, var d) in donors {
            d.members.removeAll { joining.contains($0) || $0 == id }
            donors[did] = d
        }
        for (_, b) in bounds(groups: donors, panes: panes)
            where Overlap.overlaps(grown, b) {
            return false
        }
        for (pid, r) in panes where pid != id && !joining.contains(pid) {
            if Overlap.overlaps(grown, r) { return false }
        }
        return true
    }

    // Obstacles for moving/resizing `moving` (a member of `memberOf`).
    // Foreign groups appear ONCE, as their bounds (which already cover
    // their members' frames + padding). Listing member frames alongside
    // double-counts the same pane at two rects, and pushOut's
    // least-penetration choice then flips with relative rect sizes.
    // Pane frames follow the overlap policy otherwise; members always
    // avoid non-members (a member dragged onto a loose pane would drag
    // its bounds over it).
    public static func moveObstacles(moving: PaneID, memberOf: Set<GroupID>,
                                     panes: [PaneID: Rect],
                                     groups: [GroupID: GroupMeta],
                                     allowOverlap: Bool,
                                     floating: Set<PaneID> = []) -> [Rect] {
        let b = bounds(groups: groups, panes: panes)
        var out = [Rect]()
        var foreignMembers = Set<PaneID>()
        for (id, r) in b where !memberOf.contains(id) {
            out.append(r)
            foreignMembers.formUnion(groups[id]?.members ?? [])
        }
        // Floating movers ignore same-scope frames only: a grouped
        // floater may overlap siblings but still avoids loose panes (it
        // floats over its own group, nothing else); a groupless floater
        // roams free. Foreign group bounds (above) always bind. Floating
        // frames never block anyone — tiled movers slide under them.
        if floating.contains(moving) {
            if !memberOf.isEmpty {
                var inside = Set<PaneID>()
                for m in memberOf { inside.formUnion(groups[m]?.members ?? []) }
                var grouped = Set<PaneID>()
                for g in groups.values { grouped.formUnion(g.members) }
                for (id, r) in panes
                    where id != moving && !inside.contains(id)
                        && !grouped.contains(id) && !floating.contains(id) {
                    out.append(r)
                }
            }
            return out
        }
        if !allowOverlap {
            for (id, r) in panes
                where id != moving && !foreignMembers.contains(id)
                    && !floating.contains(id) {
                out.append(r)
            }
        } else if !memberOf.isEmpty {
            var inside = Set<PaneID>()
            for m in memberOf { inside.formUnion(groups[m]?.members ?? []) }
            for (id, r) in panes
                where id != moving && !inside.contains(id)
                    && !foreignMembers.contains(id) && !floating.contains(id) {
                out.append(r)
            }
        }
        return out
    }
    // Obstacles for placing a brand-new (groupless, tiled) pane. Floating
    // panes never block creation; new panes slide under them.
    public static func creationObstacles(paneRects: [PaneID: Rect],
                                         groups: [GroupID: GroupMeta],
                                         allowOverlap: Bool,
                                         floating: Set<PaneID> = []) -> [Rect] {
        var out = [Rect]()
        if !allowOverlap {
            for (id, r) in paneRects where !floating.contains(id) {
                out.append(r)
            }
        }
        for (_, r) in bounds(groups: groups, panes: paneRects) { out.append(r) }
        return out
    }
    // One shove unit: a lone pane ([pane], isGroup false) or a whole
    // foreign group (bounds + every member, moved together by the same
    // delta, isGroup true).
    public struct ShoveUnit {
        public var rect: Rect
        public var panes: [PaneID]
        public var isGroup: Bool
        public init(rect: Rect, panes: [PaneID], isGroup: Bool = false) {
            self.rect = rect; self.panes = panes; self.isGroup = isGroup
        }
    }
    // Units a member-initiated shove may push: foreign groups as blocks
    // plus every ungrouped pane solo. Own-group members are NEVER units
    // (the group moves rigidly; members slide around siblings via the
    // caller's own resolve, never by shoving them). Foreign-group
    // members are covered by their block unit only — never double-driven
    // as solo units (that made multi-member blocks non-rigid and
    // order-dependent).
    public static func shoveUnits(moving: PaneID, memberOf: Set<GroupID>,
                                  panes: [PaneID: Rect],
                                  groups: [GroupID: GroupMeta],
                                  floating: Set<PaneID> = []) -> [ShoveUnit] {
        var units = [ShoveUnit]()
        let b = bounds(groups: groups, panes: panes)
        var foreignMembers = Set<PaneID>()
        for (id, r) in b where !memberOf.contains(id) {
            let members = (groups[id]?.members ?? []).filter { panes[$0] != nil }
            foreignMembers.formUnion(members)
            units.append(ShoveUnit(rect: r, panes: members, isGroup: true))
        }
        var inside = Set<PaneID>()
        for m in memberOf { inside.formUnion(groups[m]?.members ?? []) }
        for (id, r) in panes
            where id != moving && !inside.contains(id)
                && !foreignMembers.contains(id) && !floating.contains(id) {
            units.append(ShoveUnit(rect: r, panes: [id]))
        }
        return units
    }
    // other visible frame to union with... actually returns the
    // candidate + padding even solo — bounds() needs ≥1 frame, and the
    // candidate supplies it. Nil only when the group id is unknown.
    public static func grownRect(moving: PaneID, memberOf: GroupID,
                                 candidate: Rect,
                                 panes: [PaneID: Rect],
                                 groups: [GroupID: GroupMeta]) -> Rect? {
        guard groups[memberOf] != nil else { return nil }
        var varied = panes
        varied[moving] = candidate
        return bounds(groups: groups, panes: varied)[memberOf]
    }

    // Push foreign units out of `grown` along (axis, sign). Returns new
    // rects for the foreign panes that moved (only those). Deterministic
    // across processes (pushForResize sorts internally; the zip-back is
    // positional per caller-side unit order, which maps correctly on
    // both sides). When overlap is allowed, solo panes move only on
    // grown contact (free overlap elsewhere); foreign groups always
    // participate (still exclusive).
    public static func shoveAside(grown: Rect,
                                  moving: PaneID, memberOf: Set<GroupID>,
                                  panes: [PaneID: Rect],
                                  groups: [GroupID: GroupMeta],
                                  axis: Overlap.Axis, sign: Int,
                                  allowOverlap: Bool,
                                  floating: Set<PaneID> = [],
                                  gap: Double = 0) -> [PaneID: Rect] {
        var units = shoveUnits(moving: moving, memberOf: memberOf,
                               panes: panes, groups: groups,
                               floating: floating)
        if allowOverlap {
            units = units.filter {
                $0.isGroup || Overlap.overlaps($0.rect, grown)
            }
        }
        guard !units.isEmpty else { return [:] }
        let frames = units.map(\.rect)
        let pushed = Overlap.pushForResize(grown, obstacles: frames,
                                           axis: axis, sign: sign, gap: gap)
        var out = [PaneID: Rect]()
        for (unit, frame) in zip(units, pushed) {
            let dx = frame.x - unit.rect.x, dy = frame.y - unit.rect.y
            guard dx != 0 || dy != 0 else { continue }
            for pid in unit.panes {
                guard let r = panes[pid] else { continue }
                out[pid] = Rect(x: r.x + dx, y: r.y + dy, w: r.w, h: r.h)
            }
        }
        return out
    }
    // Obstacles for a rigid group-block move: every UNGROUPED pane plus
    // every other group's bounds. Always enforced. Foreign members are
    // covered by their block bounds — never double-listed as frames
    // (see moveObstacles). Floating panes never block: blocks slide
    // under them.
    public static func blockObstacles(moving: GroupID,
                                      panes: [PaneID: Rect],
                                      groups: [GroupID: GroupMeta],
                                      floating: Set<PaneID> = []) -> [Rect] {
        let members = Set(groups[moving]?.members ?? [])
        var grouped = Set<PaneID>()
        for (id, g) in groups where id != moving {
            grouped.formUnion(g.members)
        }
        var out = [Rect]()
        for (id, r) in panes
            where !members.contains(id) && !grouped.contains(id)
                && !floating.contains(id) {
            out.append(r)
        }
        for (id, r) in bounds(groups: groups, panes: panes)
            where id != moving { out.append(r) }
        return out
    }

    // True when `candidate` (a member's proposed rect) grows its own
    // group's bounds over anything foreign: another group's bounds OR
    // any non-member pane frame. The padding overhang counts — bounds
    // are exclusion zones, not just member frames. Shared by canvas
    // (slide/hold for drags) and daemon (backstop).
    public static func grownClash(moving: PaneID, memberOf: GroupID,
                                  candidate: Rect,
                                  panes: [PaneID: Rect],
                                  groups: [GroupID: GroupMeta],
                                  floating: Set<PaneID> = []) -> Bool {
        // Floating members stretch the bounds over siblings freely;
        // loose panes and foreign bounds still bind.
        if floating.contains(moving) {
            var varied = panes
            varied[moving] = candidate
            let live = bounds(groups: groups, panes: varied)
            guard let mine = live[memberOf] else { return false }
            for (id, b) in live where id != memberOf {
                if Overlap.overlaps(mine, b) { return true }
            }
            var grouped = Set<PaneID>()
            for g in groups.values { grouped.formUnion(g.members) }
            for (id, r) in varied
                where id != moving && !grouped.contains(id)
                    && !floating.contains(id) {
                if Overlap.overlaps(mine, r) { return true }
            }
            return false
        }
        var varied = panes
        varied[moving] = candidate
        let live = bounds(groups: groups, panes: varied)
        guard let mine = live[memberOf] else { return false }
        for (id, b) in live where id != memberOf {
            if Overlap.overlaps(mine, b) { return true }
        }
        let inside = Set(groups[memberOf]?.members ?? [])
        for (id, r) in varied
            where id != moving && !inside.contains(id) {
            if Overlap.overlaps(mine, r) { return true }
        }
        return false
    }

    // Slide a clashing member candidate along its grown bounds: resolve
    // the grown rect against foreign obstacles, shift the candidate by
    // the result. Lets drags glide along walls instead of sticking on
    // the padding graze. Total function — caller re-checks grownClash
    // and holds if it still clashes.
    public static func slideGrownRect(candidate: Rect,
                                      moving: PaneID, memberOf: GroupID,
                                      panes: [PaneID: Rect],
                                      groups: [GroupID: GroupMeta],
                                      floating: Set<PaneID> = []) -> Rect {
        var varied = panes
        varied[moving] = candidate
        guard let grown = bounds(groups: groups, panes: varied)[memberOf]
            else { return candidate }
        var foreign = [Rect]()
        for (id, b) in bounds(groups: groups, panes: varied)
            where id != memberOf { foreign.append(b) }
        if floating.contains(moving) {
            var grouped = Set<PaneID>()
            for g in groups.values { grouped.formUnion(g.members) }
            for (id, r) in varied
                where id != moving && !grouped.contains(id)
                    && !floating.contains(id) {
                foreign.append(r)
            }
        } else {
            let inside = Set(groups[memberOf]?.members ?? [])
            for (id, r) in varied
                where id != moving && !inside.contains(id)
                    && !floating.contains(id) {
                foreign.append(r)
            }
        }
        let clean = Overlap.resolve(grown, obstacles: foreign)
        return Rect(x: candidate.x + (clean.x - grown.x),
                    y: candidate.y + (clean.y - grown.y),
                    w: candidate.w, h: candidate.h)
    }
}
// MARK: - Group style
public enum GroupStyle {
    // Defaults cycled on create.
    public static let palette = [
        "#3b82f6", "#22c55e", "#a855f7", "#f59e0b",
        "#ec4899", "#14b8af",
    ]
    // "#rgb"/"#rrggbb"/"#rgba"/"#rrggbbaa", "#" optional.
    public static func sanitizedColor(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8,
              UInt32(s, radix: 16) != nil else { return nil }
        return "#" + s.lowercased()
    }
    public static func sanitizedName(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { return nil }
        return String(t.prefix(128))
    }
}
