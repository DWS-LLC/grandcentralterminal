// Cables between panes that spawned each other: Verlet ropes with ties.
//
//        ┌────────┐ port                         port ┌────────┐
//        │ parent ├──╮     ties keep strands      ╭───┤ child  │
//        └────────┘  ╰──╥══════════╥══════════════╯   └────────┘
//                       tie        tie     (slide along the cable;
//                                           they never pass each other)
//
//   rope   N points, fixed-length links, a little gravity. Both ends are
//          pinned to a port on a pane edge, and the first link leaves the
//          edge square, so a cable never exits sideways.
//   ports  each pane side spreads its cables along the edge, ordered by
//          where the other end sits, so strands leave uncrossed.
//   tie    gathers the strands passing through one spot into a parallel
//          bundle. Ties on a shared cable keep their order and a gap.
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
    public fileprivate(set) var pts: [Vec]
    fileprivate var prev: [Vec]
    fileprivate var seg: Double
    // The fair curve between the ports: the rope sags and sways around it
    // and is pulled gently back, so cables keep a designed look.
    fileprivate var shape: [Vec]
}

public struct CableTie: Sendable {
    public struct Member: Sendable {
        public var key: CableKey
        // Index offset from the tie's own, so strands that pass the tie
        // at slightly different points stay where they were gripped.
        public var delta: Int
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
        public var index: Int
        public var distance: Double
    }

    public static let points = 32
    // Where along the cable a fan-out's tie first sits, nearest first. A
    // tie only goes where its strands are still travelling together.
    private static let fanOutS = [0.3, 0.2]
    private static let fanOutSpread = 48.0
    // A slid tie holds strands no wider apart than this.
    private static let holdSpread = 64.0
    private static let portSpacing = 8.0
    private static let slack = 1.04
    private static let gravity = 520.0
    private static let damping = 0.985
    private static let dt = 1.0 / 120
    private static let substeps = 2
    private static let iterations = 12
    private static let minBend = 1.9
    private static let bendStiffness = 0.15
    // Share of each point's offset from its neighbors' midpoint removed per
    // iteration: what keeps a rope fair instead of kinked.
    private static let rigidity = 0.4
    // Share of the distance back to the fair curve closed per iteration.
    private static let shapePull = 0.05
    private static let strandGap = 3.2
    private static let tieThickness = 7.0
    private static let tieStiffness = 0.7
    private static let tieReach = 3
    private static let tieEnds = 3
    private static let tieGap = 12.0
    private static let bundleRadius = 12.0
    private static let calmMove = 0.004
    private static let calmFrames = 45
    private static let moved = 0.01
    private static let bezierSamples = 32

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

        c.a = a
        c.b = b
        c.seg = Self.ideal(a, b) / Double(Self.points - 1)
        c.shape = Self.sample(a, b)
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

    // Bezier that leaves each port square to its edge.
    private static func curve(_ a: CableEnd, _ b: CableEnd, _ t: Double) -> Vec {
        let d = handle(a, b)
        let p0 = a.point, p1 = a.point + a.normal * d
        let p2 = b.point + b.normal * d, p3 = b.point
        let u = 1 - t
        return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
    }

    private static func handle(_ a: CableEnd, _ b: CableEnd) -> Double {
        min(300, max(30, (a.point - b.point).length * 0.45))
    }

    private static func ideal(_ a: CableEnd, _ b: CableEnd) -> Double {
        var len = 0.0
        var last = a.point
        for i in 1...bezierSamples {
            let p = curve(a, b, Double(i) / Double(bezierSamples))
            len += (p - last).length
            last = p
        }
        return len * slack
    }

    private static func sample(_ a: CableEnd, _ b: CableEnd) -> [Vec] {
        (0..<points).map { curve(a, b, Double($0) / Double(points - 1)) }
    }

    private static func make(a: CableEnd, b: CableEnd) -> Cable {
        let pts = sample(a, b)
        return Cable(a: a, b: b, pts: pts, prev: pts, seg: ideal(a, b) / Double(points - 1),
                     shape: pts)
    }

    // MARK: Step

    // One display frame: a few small, fixed steps. Same input, same motion.
    public func step() {
        guard isAwake else { return }

        var worst = 0.0
        for _ in 0..<Self.substeps {
            worst = max(worst, advance())
        }

        calm = worst < Self.calmMove ? calm + 1 : 0
        if calm >= Self.calmFrames { isAwake = false }
        refreshTies()
    }

    // Returns the fastest point's travel this step.
    private func advance() -> Double {
        let n = Self.points
        let pull = Vec(0, -Self.gravity * Self.dt * Self.dt)

        for key in cables.keys {
            guard var c = cables[key] else { continue }
            for i in 2..<(n - 2) {
                let p = c.pts[i]
                let v = (p - c.prev[i]) * Self.damping
                c.prev[i] = p
                c.pts[i] = p + v + pull
            }
            Self.pin(&c)
            cables[key] = c
        }

        for _ in 0..<Self.iterations {
            for key in cables.keys {
                guard var c = cables[key] else { continue }
                Self.constrain(&c)
                cables[key] = c
            }
            squeezeTies()
        }

        // Travel after the constraints: gravity alone is not motion once
        // the links hold the rope up.
        var worst = 0.0
        for c in cables.values {
            for i in 2..<(n - 2) { worst = max(worst, (c.pts[i] - c.prev[i]).length) }
        }
        return worst
    }

    // Ends sit on their ports, and the first link leaves each edge square.
    private static func pin(_ c: inout Cable) {
        let n = points
        c.pts[0] = c.a.point
        c.pts[1] = c.a.point + c.a.normal * c.seg
        c.pts[n - 1] = c.b.point
        c.pts[n - 2] = c.b.point + c.b.normal * c.seg
        for i in [0, 1, n - 2, n - 1] { c.prev[i] = c.pts[i] }
    }

    private static func free(_ i: Int) -> Double { (2...(points - 3)).contains(i) ? 1 : 0 }

    private static func constrain(_ c: inout Cable) {
        let n = points

        for i in 0..<(n - 1) {
            let wa = free(i), wb = free(i + 1)
            guard wa + wb > 0 else { continue }
            let d = c.pts[i + 1] - c.pts[i]
            let len = max(d.length, 1e-9)
            let fix = d * ((len - c.seg) / len)
            c.pts[i] = c.pts[i] + fix * (wa / (wa + wb))
            c.pts[i + 1] = c.pts[i + 1] - fix * (wb / (wa + wb))
        }

        for i in 2..<(n - 2) {
            let mid = (c.pts[i - 1] + c.pts[i + 1]) * 0.5
            c.pts[i] = c.pts[i] + (mid - c.pts[i]) * rigidity
            c.pts[i] = c.pts[i] + (c.shape[i] - c.pts[i]) * shapePull
        }

        // Stiffness: refuse folds sharper than a few links.
        let floor = minBend * c.seg
        for i in 0..<(n - 2) {
            let wa = free(i), wb = free(i + 2)
            guard wa + wb > 0 else { continue }
            let d = c.pts[i + 2] - c.pts[i]
            let len = max(d.length, 1e-9)
            guard len < floor else { continue }
            let push = d * ((len - floor) / len * bendStiffness)
            c.pts[i] = c.pts[i] + push * (wa / (wa + wb))
            c.pts[i + 2] = c.pts[i + 2] - push * (wb / (wa + wb))
        }
    }

    // MARK: Ties

    private func index(_ t: CableTie, _ m: CableTie.Member) -> Int {
        let k = Int((t.s * Double(Self.points - 1)).rounded()) + m.delta
        return min(max(k, Self.tieEnds), Self.points - 1 - Self.tieEnds)
    }

    // Pull the strands through each tie into parallel slots across the
    // bundle: nearest the ends the pull fades, so cables fan out smoothly.
    private func squeezeTies() {
        for t in ties {
            let live = t.members.filter { cables[$0.key] != nil }
            guard !live.isEmpty else { continue }

            let k0 = live.map { index(t, $0) }
            let mid = live.indices.map { cables[live[$0].key]!.pts[k0[$0]] }
            let c = Self.mean(mid)
            let cross = Self.cross(live, k0, cables)

            // Slots follow the strands' current order across the bundle.
            let order = live.indices.sorted {
                let (p, q) = ((mid[$0] - c).dot(cross), (mid[$1] - c).dot(cross))
                return p != q ? p < q : live[$0].key.order < live[$1].key.order
            }

            for reach in -Self.tieReach...Self.tieReach {
                let weight = Self.tieStiffness * (1 - Double(abs(reach)) / Double(Self.tieReach + 1))
                let at = live.indices.map { cables[live[$0].key]!.pts[k0[$0] + reach] }
                let cr = Self.mean(at)

                for (rank, i) in order.enumerated() {
                    let slot = (Double(rank) - Double(live.count - 1) / 2) * Self.strandGap
                    let want = cr + cross * slot
                    let k = k0[i] + reach
                    guard var cable = cables[live[i].key], Self.free(k) > 0 else { continue }
                    cable.pts[k] = cable.pts[k] + (want - cable.pts[k]) * weight
                    cables[live[i].key] = cable
                }
            }
        }
    }

    // Unit vector across the bundle (perpendicular to the strands' flow).
    private static func cross(_ m: [CableTie.Member], _ k: [Int], _ cables: [CableKey: Cable]) -> Vec {
        var flow = Vec(0, 0)
        for (i, member) in m.enumerated() {
            guard let c = cables[member.key] else { continue }
            flow = flow + (c.pts[k[i] + 1] - c.pts[k[i] - 1])
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

            let k = live.map { index(t, $0) }
            let c = Self.mean(live.indices.map { cables[live[$0].key]!.pts[k[$0]] })
            let cross = Self.cross(live, k, cables)
            ties[i].center = c
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

            var t = CableTie(id: nextTie, members: keys.map { .init(key: $0, delta: 0) }, s: s)
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
    // press, when a == b).
    public func hits(along a: Vec, to b: Vec, radius: Double) -> [Hit] {
        var out = [Hit]()
        for key in cables.keys.sorted(by: { $0.order < $1.order }) {
            guard let c = cables[key] else { continue }
            var best: Hit?
            for (i, q) in c.pts.enumerated() {
                let d = Self.gap(q, a, b)
                if d <= radius, d < (best?.distance ?? .infinity) {
                    best = Hit(key: key, index: i, distance: d)
                }
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

    public func tie(near p: Vec, radius: Double) -> Int? {
        ties.filter { ($0.center - p).length <= max(radius, $0.width / 2) }
            .min { ($0.center - p).length < ($1.center - p).length }?.id
    }

    // A tie around every strand the stroke a -> b crosses (or touches).
    // Nil when it crosses none, or another tie already holds the spot.
    @discardableResult
    public func addTie(from a: Vec, to b: Vec, radius: Double? = nil) -> Int? {
        let found = hits(along: a, to: b, radius: radius ?? Self.bundleRadius)
        guard let lead = found.min(by: { $0.distance < $1.distance }) else { return nil }

        let s = Double(lead.index) / Double(Self.points - 1)
        let id = nextTie
        let members = found.map { CableTie.Member(key: $0.key, delta: $0.index - lead.index) }
        let tie = CableTie(id: id, members: members, s: s)
        guard clear(tie, at: s) == s else { return nil }

        nextTie += 1
        ties.append(tie)
        wake()
        refreshTies()
        return id
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

        let f = Self.along(c.pts, p)
        let s = (f - Double(lead.delta)) / Double(Self.points - 1)
        let next = clear(ties[i], at: s)

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
            let k = Int((s * Double(Self.points - 1)).rounded()) + m.delta
            return c.shape[min(max(k, 0), Self.points - 1)]
        }
        var widest = 0.0
        for (i, p) in at.enumerated() {
            for q in at[(i + 1)...] { widest = max(widest, (p - q).length) }
        }
        return widest
    }

    // `s` held off the cable ends and the closest ties either side.
    private func clear(_ t: CableTie, at s: Double) -> Double {
        let keys = Set(t.members.map(\.key))
        let length = Double(Self.points - 1)
        var lo = Double(Self.tieEnds + Self.tieReach) / length
        var hi = 1 - lo

        for o in ties where o.id != t.id && o.members.contains(where: { keys.contains($0.key) }) {
            let seg = keys.compactMap { cables[$0]?.seg }.max() ?? 1
            let gap = Self.tieGap / (seg * length)
            if o.s <= t.s { lo = max(lo, o.s + gap) } else { hi = min(hi, o.s - gap) }
        }
        guard lo <= hi else { return t.s }
        return min(max(s, lo), hi)
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
