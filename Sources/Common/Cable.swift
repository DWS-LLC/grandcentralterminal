// Cables between panes that spawned each other: springy Béziers with ties.
//
//        ┌────────┐ port                         port ┌────────┐
//        │ parent ├──╮     ties keep strands      ╭───┤ child  │
//        └────────┘  ╰──╥══════════╥══════════════╯   └────────┘
//                       tie        tie     (slide along the cable;
//                                           they never pass each other)
//
//   spring  a cable is a cubic Bézier whose two handles hang on springs:
//           each handle is pulled to its rest spot (out of the port, square
//           to the pane edge, drooping a little). Move a pane and the ends
//           follow at once while the handles lag, overshoot, and settle.
//   ports   each pane side spreads its cables along the edge, ordered by
//           where the other end sits, so strands leave uncrossed.
//   tie     gathers the strands passing through one spot into a parallel
//           bundle, blending back to the free curve over a few points on
//           either side. Ties on a shared cable keep their order and a gap.
//
// The sim sleeps once everything is still; moving a port, a tie, or a pane
// wakes it. Pure math, same as Spring: no AppKit, runs in the CLI.

import Foundation

public struct Vec: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public static func + (a: Vec, b: Vec) -> Vec { Vec(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec, b: Vec) -> Vec { Vec(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec, k: Double) -> Vec { Vec(a.x * k, a.y * k) }
    public var length: Double { hypot(x, y) }
    public func dot(_ o: Vec) -> Double { x * o.x + y * o.y }
}

public struct CableKey: Hashable, Sendable {
    public var parent: PaneID
    public var child: PaneID
    public init(parent: PaneID, child: PaneID) { self.parent = parent; self.child = child }

    var order: String { parent.description + child.description }
}

public struct CableEnd: Sendable, Equatable {
    public var point: Vec
    public var normal: Vec    // outward from the pane edge
}

public struct Cable: Sendable {
    public var a: CableEnd    // parent port
    public var b: CableEnd    // child port
    // What you see: the sprung curve sampled in points, ties applied.
    public fileprivate(set) var pts: [Vec]
    // The two handles and their velocities; `r1`/`r2` are where they rest.
    fileprivate var h1: Vec
    fileprivate var h2: Vec
    fileprivate var v1 = Vec(0, 0)
    fileprivate var v2 = Vec(0, 0)
    fileprivate var r1: Vec
    fileprivate var r2: Vec
    // The curve at rest: what ties and spread checks measure against.
    fileprivate var shape: [Vec]
    // `pts` before ties bent it: what a sliding tie follows, so the strand
    // it rides is not the one it is reshaping.
    fileprivate var free: [Vec]
}

public struct CableTie: Sendable {
    public struct Member: Sendable {
        public var key: CableKey
        // Point offset from the tie's own, so strands that pass the tie
        // at slightly different points stay where they were gripped.
        public var delta: Double
    }

    public var id: Int
    public var members: [Member]
    public var s: Double          // position along the cable, 0...1
    // Set for ties the sim placed itself (one per fan-out); nil = yours.
    public fileprivate(set) var fanOut: String?
    public fileprivate(set) var center = Vec(0, 0)
    public fileprivate(set) var angle = 0.0    // of the bundle's cross axis
    public fileprivate(set) var width = 0.0
}

public final class CableSim {
    public struct Edge: Sendable, Equatable {
        public var parent: Rect
        public var child: Rect
        public init(parent: Rect, child: Rect) { self.parent = parent; self.child = child }
    }

    public struct Hit: Sendable {
        public var key: CableKey
        public var at: Double    // fractional point index along the cable
        public var distance: Double
    }

    public static let points = 32
    // Where along the cable a fan-out's tie first sits, nearest first. A
    // tie only goes where its strands are still travelling together.
    private static let fanOutS = [0.35, 0.28]
    private static let fanOutSpread = 48.0
    // A slid tie holds strands no wider apart than this.
    private static let holdSpread = 120.0
    private static let portSpacing = 8.0
    // Handle springs, per second: stiffness and damping (about 0.2 of
    // critical: a few bouncy swings, then still).
    private static let stiffness = 220.0
    private static let damping = 6.0
    private static let dt = 1.0 / 120
    private static let substeps = 2
    // How far the rest handles hang below the straight pull, as a share of
    // the cable's length, and at most.
    private static let sagShare = 0.05
    private static let maxSag = 36.0
    private static let strandGap = 3.2
    private static let tieThickness = 7.0
    // Points either side of a tie that blend from the bundle back to the
    // free curve: at least `tieReach`, more when the strands start far
    // apart (so the funnel never gets steeper than ~45 degrees), at most
    // `maxReach`. And the margin a tie keeps from the cable ends.
    private static let tieReach = 6.0
    private static let maxReach = 14.0
    private static let tieEnds = 7
    private static let edgeMargin = 2.0
    private static let tieGap = 12.0
    private static let bundleRadius = 12.0
    // Asleep after this many still frames; "still" is handle speed (and
    // displacement x calmGain) under calmMove.
    private static let calmMove = 0.4
    private static let calmGain = 20.0
    private static let calmFrames = 30
    private static let moved = 0.01

    public private(set) var cables = [CableKey: Cable]()
    public private(set) var ties = [CableTie]()
    public private(set) var isAwake = false

    private var calm = 0
    private var nextTie = 1
    // Fan-outs whose tie you removed: the sim leaves them alone.
    private var declined = Set<String>()

    public init() {}

    // MARK: Edges

    public func setEdges(_ edges: [CableKey: Edge]) {
        let ends = Self.ports(edges)

        for key in cables.keys where edges[key] == nil {
            cables.removeValue(forKey: key)
            isAwake = true
        }

        for key in edges.keys.sorted(by: { $0.order < $1.order }) {
            guard let e = ends[key] else { continue }
            update(key, a: e.a, b: e.b)
        }

        syncFanOutTies(ends)
        dropOrphanTies()
    }

    private func update(_ key: CableKey, a: CableEnd, b: CableEnd) {
        guard var c = cables[key] else {
            cables[key] = Self.make(a: a, b: b)
            wake()
            return
        }
        guard !Self.same(c.a, a) || !Self.same(c.b, b) else { return }

        let (r1, r2) = Self.rest(a, b)
        c.a = a
        c.b = b
        c.r1 = r1
        c.r2 = r2
        c.shape = Self.sample(a, b, r1, r2)
        cables[key] = c
        wake()
    }

    private static func same(_ x: CableEnd, _ y: CableEnd) -> Bool {
        (x.point - y.point).length < moved && x.normal == y.normal
    }

    private func wake() {
        isAwake = true
        calm = 0
    }

    // MARK: Ports

    private enum Side { case left, right, top, bottom }

    private struct EndRef {
        var key: CableKey
        var isParent: Bool
        var rect: Rect
        var other: Vec
        var side: Side
    }

    // One port per cable end. A pane side with several cables spreads them
    // along the edge, ordered by where each cable's other end is, so
    // neighbors never cross on the way out.
    private static func ports(_ edges: [CableKey: Edge]) -> [CableKey: (a: CableEnd, b: CableEnd)] {
        var groups = [String: [EndRef]]()

        for key in edges.keys.sorted(by: { $0.order < $1.order }) {
            guard let e = edges[key] else { continue }
            let pc = center(e.parent), cc = center(e.child)
            let p = EndRef(key: key, isParent: true, rect: e.parent, other: cc,
                           side: side(of: e.parent, toward: cc))
            let c = EndRef(key: key, isParent: false, rect: e.child, other: pc,
                           side: side(of: e.child, toward: pc))
            groups[groupID(p), default: []].append(p)
            groups[groupID(c), default: []].append(c)
        }

        var a = [CableKey: CableEnd](), b = [CableKey: CableEnd]()
        for group in groups.values {
            for (ref, end) in place(group) {
                if ref.isParent { a[ref.key] = end } else { b[ref.key] = end }
            }
        }

        var out = [CableKey: (a: CableEnd, b: CableEnd)]()
        for key in edges.keys {
            if let x = a[key], let y = b[key] { out[key] = (x, y) }
        }
        return out
    }

    private static func groupID(_ r: EndRef) -> String {
        let pane = r.isParent ? r.key.parent : r.key.child
        return "\(pane)\(r.side)"
    }

    private static func place(_ group: [EndRef]) -> [(EndRef, CableEnd)] {
        guard let first = group.first else { return [] }

        let vertical = first.side == .left || first.side == .right
        let sorted = group.sorted {
            let (p, q) = vertical ? ($0.other.y, $1.other.y) : ($0.other.x, $1.other.x)
            return p != q ? p < q : $0.key.order < $1.key.order
        }

        let r = first.rect
        let edge = vertical ? r.h : r.w
        let spacing = min(portSpacing, edge / Double(sorted.count + 1))
        let c = center(r)

        return sorted.enumerated().map { i, ref in
            let off = (Double(i) - Double(sorted.count - 1) / 2) * spacing
            switch ref.side {
            case .right: return (ref, CableEnd(point: Vec(r.x + r.w, c.y + off), normal: Vec(1, 0)))
            case .left: return (ref, CableEnd(point: Vec(r.x, c.y + off), normal: Vec(-1, 0)))
            case .top: return (ref, CableEnd(point: Vec(c.x + off, r.y + r.h), normal: Vec(0, 1)))
            case .bottom: return (ref, CableEnd(point: Vec(c.x + off, r.y), normal: Vec(0, -1)))
            }
        }
    }

    // Which side of `r` faces `o` (y grows up).
    private static func side(of r: Rect, toward o: Vec) -> Side {
        let c = center(r)
        let dx = (o.x - c.x) / max(r.w, 1), dy = (o.y - c.y) / max(r.h, 1)
        if abs(dx) >= abs(dy) { return dx >= 0 ? .right : .left }
        return dy >= 0 ? .top : .bottom
    }

    private static func center(_ r: Rect) -> Vec { Vec(r.x + r.w / 2, r.y + r.h / 2) }

    // MARK: Shape

    private static func bezier(_ p0: Vec, _ p1: Vec, _ p2: Vec, _ p3: Vec, _ t: Double) -> Vec {
        let u = 1 - t
        return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
    }

    // Where the handles rest: out of each port, square to its edge, hanging
    // a little under their own weight.
    private static func rest(_ a: CableEnd, _ b: CableEnd) -> (Vec, Vec) {
        let chord = (a.point - b.point).length
        let reach = min(300, max(30, chord * 0.45))
        let droop = Vec(0, -min(maxSag, chord * sagShare))
        return (a.point + a.normal * reach + droop, b.point + b.normal * reach + droop)
    }

    private static func sample(_ a: CableEnd, _ b: CableEnd, _ h1: Vec, _ h2: Vec) -> [Vec] {
        (0..<points).map { bezier(a.point, h1, h2, b.point, Double($0) / Double(points - 1)) }
    }

    // The curve at rest, at fraction `t`.
    private static func curve(_ a: CableEnd, _ b: CableEnd, _ t: Double) -> Vec {
        let (r1, r2) = rest(a, b)
        return bezier(a.point, r1, r2, b.point, t)
    }

    private static func make(a: CableEnd, b: CableEnd) -> Cable {
        let (r1, r2) = rest(a, b)
        let pts = sample(a, b, r1, r2)
        return Cable(a: a, b: b, pts: pts, h1: r1, h2: r2, r1: r1, r2: r2, shape: pts, free: pts)
    }

    // MARK: Step

    // One display frame: a couple of small, fixed spring steps, then the
    // curve is re-sampled and the ties pulled in. Same input, same motion.
    public func step() {
        guard isAwake else { return }

        var worst = 0.0
        for _ in 0..<Self.substeps {
            worst = max(worst, spring())
        }

        for key in cables.keys {
            guard var c = cables[key] else { continue }
            c.pts = Self.sample(c.a, c.b, c.h1, c.h2)
            c.free = c.pts
            cables[key] = c
        }
        bundleTies()
        refreshTies()

        calm = worst < Self.calmMove ? calm + 1 : 0
        if calm >= Self.calmFrames { isAwake = false }
    }

    // Each handle is a damped spring on its rest spot. Returns how far from
    // still the worst handle is.
    private func spring() -> Double {
        var worst = 0.0

        for key in cables.keys {
            guard var c = cables[key] else { continue }
            Self.pull(&c.h1, &c.v1, toward: c.r1)
            Self.pull(&c.h2, &c.v2, toward: c.r2)
            worst = max(worst, c.v1.length, c.v2.length,
                        (c.h1 - c.r1).length * Self.calmGain, (c.h2 - c.r2).length * Self.calmGain)
            cables[key] = c
        }
        return worst
    }

    private static func pull(_ h: inout Vec, _ v: inout Vec, toward r: Vec) {
        let acc = (r - h) * stiffness - v * damping
        v = v + acc * dt
        h = h + v * dt
    }

    // MARK: Ties

    // Fractional point index where the tie grips member `m`.
    private func place(_ t: CableTie, _ m: CableTie.Member) -> Double {
        let f = t.s * Double(Self.points - 1) + m.delta
        return min(max(f, Self.edgeMargin), Double(Self.points - 1) - Self.edgeMargin)
    }

    // The polyline at fractional index `f`.
    private static func at(_ pts: [Vec], _ f: Double) -> Vec {
        let g = min(max(f, 0), Double(pts.count - 1))
        let i = min(Int(g), pts.count - 2)
        return pts[i] + (pts[i + 1] - pts[i]) * (g - Double(i))
    }

    // Pull the strands through each tie into parallel slots across the
    // bundle. The pull is full at the tie and eases to nothing over `reach`
    // points either side, so cables fan out smoothly. The tie sits at a
    // fractional point, so sliding it is continuous, not point to point.
    private func bundleTies() {
        for t in ties {
            let live = t.members.filter { cables[$0.key] != nil }
            guard !live.isEmpty else { continue }

            let snap = live.map { cables[$0.key]!.pts }
            let f = live.map { place(t, $0) }
            let mid = live.indices.map { Self.at(snap[$0], f[$0]) }
            let c = Self.mean(mid)
            let cross = Self.cross(snap, f)
            let reach = Self.reach(mid, around: c, seg: Self.length(snap[0]) / Double(Self.points - 1))

            // Slots follow the strands' order across the bundle.
            let order = live.indices.sorted {
                let (p, q) = ((mid[$0] - c).dot(cross), (mid[$1] - c).dot(cross))
                return p != q ? p < q : live[$0].key.order < live[$1].key.order
            }

            for (rank, i) in order.enumerated() {
                let slot = (Double(rank) - Double(live.count - 1) / 2) * Self.strandGap
                guard var cable = cables[live[i].key] else { continue }

                let first = max(Int((f[i] - reach).rounded(.up)), 1)
                let last = min(Int((f[i] + reach).rounded(.down)), Self.points - 2)
                guard first <= last else { continue }

                for j in first...last {
                    let off = Double(j) - f[i]
                    let fade = cos(Double.pi / 2 * abs(off) / (reach + 1))
                    let cr = Self.mean(live.indices.map { Self.at(snap[$0], f[$0] + off) })
                    let want = cr + cross * slot
                    cable.pts[j] = cable.pts[j] + (want - cable.pts[j]) * (fade * fade)
                }
                cables[live[i].key] = cable
            }
        }
    }

    // Points a funnel needs: far-apart strands take a longer, gentler one.
    private static func reach(_ mid: [Vec], around c: Vec, seg: Double) -> Double {
        let pull = mid.map { ($0 - c).length }.max() ?? 0
        return min(max(pull / max(seg, 1), tieReach), maxReach)
    }

    // Unit vector across the bundle (perpendicular to the strands' flow).
    // Strands running the opposite way are flipped so they don't cancel.
    private static func cross(_ snap: [[Vec]], _ f: [Double]) -> Vec {
        var flow = Vec(0, 0)
        var lead: Vec?

        for (pts, k) in zip(snap, f) {
            var d = at(pts, k + 1) - at(pts, k - 1)
            if let lead, d.dot(lead) < 0 { d = d * -1 }
            lead = lead ?? d
            flow = flow + d
        }
        let len = max(flow.length, 1e-9)
        return Vec(-flow.y / len, flow.x / len)
    }

    private static func mean(_ v: [Vec]) -> Vec {
        let sum = v.reduce(Vec(0, 0), +)
        return sum * (1 / Double(max(v.count, 1)))
    }

    private func refreshTies() {
        for i in ties.indices {
            let t = ties[i]
            let live = t.members.filter { cables[$0.key] != nil }
            guard !live.isEmpty else { continue }

            let snap = live.map { cables[$0.key]!.pts }
            let f = live.map { place(t, $0) }
            let cross = Self.cross(snap, f)
            ties[i].center = Self.mean(live.indices.map { Self.at(snap[$0], f[$0]) })
            ties[i].angle = atan2(cross.y, cross.x)
            ties[i].width = Double(live.count - 1) * Self.strandGap + Self.tieThickness
        }
    }

    // Fan-outs: two or more cables leaving one pane side get a tie of
    // their own, so the strands travel together, but only where they do
    // travel together: a tie across strands heading opposite ways knots.
    private func syncFanOutTies(_ ends: [CableKey: (a: CableEnd, b: CableEnd)]) {
        var groups = [String: [CableKey]]()
        for (key, e) in ends {
            groups["\(key.parent)\(e.a.normal.x),\(e.a.normal.y)", default: []].append(key)
        }

        let wanted = groups.filter { $0.value.count >= 2 }
            .mapValues { $0.sorted { $0.order < $1.order } }

        ties.removeAll { t in
            guard let id = t.fanOut else { return false }
            guard let keys = wanted[id], Set(keys) == Set(t.members.map(\.key)) else { return true }
            return Self.spread(keys, at: t.s, ends) > Self.fanOutSpread * 1.5
        }
        declined = declined.filter { wanted[$0] != nil }

        for id in wanted.keys.sorted() {
            let keys = wanted[id]!
            guard !declined.contains(id), !ties.contains(where: { $0.fanOut == id }),
                  let s = Self.fanOutS.first(where: { Self.spread(keys, at: $0, ends) <= Self.fanOutSpread })
            else { continue }

            var t = CableTie(id: nextTie, members: keys.map { .init(key: $0, delta: 0.0) }, s: s)
            t.fanOut = id
            nextTie += 1
            ties.append(t)
        }
        refreshTies()
    }

    // Widest gap between the strands' fair curves at fraction `s`.
    private static func spread(_ keys: [CableKey], at s: Double,
                               _ ends: [CableKey: (a: CableEnd, b: CableEnd)]) -> Double {
        let at = keys.compactMap { k in ends[k].map { curve($0.a, $0.b, s) } }
        var widest = 0.0
        for (i, p) in at.enumerated() {
            for q in at[(i + 1)...] { widest = max(widest, (p - q).length) }
        }
        return widest
    }

    private func dropOrphanTies() {
        ties.removeAll { t in !t.members.contains { cables[$0.key] != nil } }
    }

    // MARK: Interaction

    // Nearest point of every cable within `radius` of the stroke a -> b (a
    // press, when a == b). Measured to the rope between its points, so a
    // press anywhere along a cable lands, not just near a vertex.
    public func hits(along a: Vec, to b: Vec, radius: Double) -> [Hit] {
        var out = [Hit]()
        for key in cables.keys.sorted(by: { $0.order < $1.order }) {
            guard let c = cables[key] else { continue }
            var best: Hit?

            for i in 0..<(c.pts.count - 1) {
                let h = Self.touch(a, b, c.pts[i], c.pts[i + 1])
                guard h.gap <= radius, h.gap < (best?.distance ?? .infinity) else { continue }
                best = Hit(key: key, at: Double(i) + h.t, distance: h.gap)
            }
            if let best { out.append(best) }
        }
        return out
    }

    public func hits(near p: Vec, radius: Double) -> [Hit] {
        hits(along: p, to: p, radius: radius)
    }

    // Distance from `p` to the segment a-b.
    private static func gap(_ p: Vec, _ a: Vec, _ b: Vec) -> Double {
        let ab = b - a
        let len2 = ab.dot(ab)
        guard len2 > 1e-9 else { return (p - a).length }

        let t = min(max((p - a).dot(ab) / len2, 0), 1)
        return (p - (a + ab * t)).length
    }

    // Closest approach of the stroke a-b to the rope segment c-d: the
    // distance (0 when they cross) and how far along c-d it happens (0...1).
    private static func touch(_ a: Vec, _ b: Vec, _ c: Vec, _ d: Vec) -> (gap: Double, t: Double) {
        let r = b - a, q = d - c
        if crosses(a, b, c, d) {
            let denom = r.x * q.y - r.y * q.x
            let t = ((c.x - a.x) * r.y - (c.y - a.y) * r.x) / denom
            return (0, min(max(t, 0), 1))
        }

        var best = (gap: gap(c, a, b), t: 0.0)
        let end = gap(d, a, b)
        if end < best.gap { best = (end, 1) }

        let len2 = max(q.dot(q), 1e-9)
        for p in [a, b] {
            let t = min(max((p - c).dot(q) / len2, 0), 1)
            let g = (p - (c + q * t)).length
            if g < best.gap { best = (g, t) }
        }
        return best
    }

    private static func crosses(_ a: Vec, _ b: Vec, _ c: Vec, _ d: Vec) -> Bool {
        func side(_ p: Vec, _ q: Vec, _ r: Vec) -> Double {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        return side(a, b, c) * side(a, b, d) < 0 && side(c, d, a) * side(c, d, b) < 0
    }

    // The tie whose pill is under `p`, give or take `radius / 2`. Measured
    // in the pill's own frame, so a strand running past it is not a grab.
    public func tie(near p: Vec, radius: Double) -> Int? {
        let slop = radius / 2

        func hit(_ t: CableTie) -> Bool {
            let d = p - t.center
            let across = abs(d.x * cos(t.angle) + d.y * sin(t.angle))
            let along = abs(-d.x * sin(t.angle) + d.y * cos(t.angle))
            return across <= t.width / 2 + slop && along <= Self.tieThickness / 2 + slop
        }
        return ties.filter(hit).min { ($0.center - p).length < ($1.center - p).length }?.id
    }

    // A tie around every strand the stroke a -> b crosses (or touches).
    // Nil unless it meets two or more: one strand has nothing to bundle.
    // A spot too near the ends or another tie slides to the nearest free one.
    @discardableResult
    public func addTie(from a: Vec, to b: Vec, radius: Double? = nil) -> Int? {
        let found = hits(along: a, to: b, radius: radius ?? Self.bundleRadius)
        guard found.count >= 2, let lead = found.min(by: { $0.distance < $1.distance }) else { return nil }

        let members = found.map { CableTie.Member(key: $0.key, delta: $0.at - lead.at) }
        var tie = CableTie(id: nextTie, members: members, s: lead.at / Double(Self.points - 1))
        guard let s = clear(tie, at: tie.s) else { return nil }

        tie.s = s
        nextTie += 1
        ties.append(tie)
        wake()
        refreshTies()
        return tie.id
    }

    public func removeTie(_ id: Int) {
        guard let t = ties.first(where: { $0.id == id }) else { return }
        if let fan = t.fanOut { declined.insert(fan) }
        ties.removeAll { $0.id == id }
        wake()
    }

    // Slide a tie toward `p`, along its cable. It stops at the ends and at
    // its neighbors on any shared cable: ties never pass or overlap.
    public func moveTie(_ id: Int, to p: Vec) {
        guard let i = ties.firstIndex(where: { $0.id == id }),
              let lead = ties[i].members.first(where: { cables[$0.key] != nil }),
              let c = cables[lead.key] else { return }

        let f = Self.along(c.free, p)
        let s = (f - lead.delta) / Double(Self.points - 1)
        guard let next = clear(ties[i], at: s) else { return }

        // Strands that part ways would knot at the tie: it stops where they
        // do, but may always slide back toward where they run together.
        let now = grip(ties[i], at: ties[i].s)
        if grip(ties[i], at: next) > Self.holdSpread, grip(ties[i], at: next) > now { return }

        ties[i].s = next
        wake()
        refreshTies()
    }

    // Widest gap between the tie's strands (their fair curves) at `s`.
    private func grip(_ t: CableTie, at s: Double) -> Double {
        let at = t.members.compactMap { m -> Vec? in
            guard let c = cables[m.key] else { return nil }
            return Self.at(c.shape, s * Double(Self.points - 1) + m.delta)
        }
        var widest = 0.0
        for (i, p) in at.enumerated() {
            for q in at[(i + 1)...] { widest = max(widest, (p - q).length) }
        }
        return widest
    }

    // `s` held off the cable ends and the closest ties either side.
    private func clear(_ t: CableTie, at s: Double) -> Double? {
        let keys = Set(t.members.map(\.key))
        let length = Double(Self.points - 1)
        var lo = Double(Self.tieEnds) / length
        var hi = 1 - lo

        for o in ties where o.id != t.id && o.members.contains(where: { keys.contains($0.key) }) {
            let long = keys.compactMap { cables[$0].map { Self.length($0.shape) } }.max() ?? 1
            let gap = Self.tieGap / long
            if o.s <= t.s { lo = max(lo, o.s + gap) } else { hi = min(hi, o.s - gap) }
        }
        guard lo <= hi else { return nil }
        return min(max(s, lo), hi)
    }

    private static func length(_ pts: [Vec]) -> Double {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
    }

    // Fractional point index of the spot on the polyline nearest to `p`.
    private static func along(_ pts: [Vec], _ p: Vec) -> Double {
        var best = (d: Double.infinity, f: 0.0)

        for i in 0..<(pts.count - 1) {
            let a = pts[i], ab = pts[i + 1] - a
            let len2 = max(ab.dot(ab), 1e-9)
            let t = min(max((p - a).dot(ab) / len2, 0), 1)
            let d = (a + ab * t - p).length
            if d < best.d { best = (d, Double(i) + t) }
        }
        return best.f
    }
}
