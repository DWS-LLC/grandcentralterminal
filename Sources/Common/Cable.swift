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
//   tie     a waypoint every strand passes through, side by side, running
//           parallel for a short stretch. Each strand is re-drawn as smooth
//           curves port -> tie -> port, so strands stretch to the tie from
//           anywhere (no length is conserved, no humps). Ties on a shared
//           cable keep their order and a gap.
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
    // What you see: the sprung curve, re-drawn through its ties.
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
    // The sprung curve in `points` samples, ties ignored: where ties sit
    // (their `s` indexes it) and what a sliding tie follows.
    fileprivate var free: [Vec]
}

public struct CableTie: Sendable {
    public struct Member: Sendable {
        public var key: CableKey
        // Point offset from the tie's own, so strands that pass the tie
        // at slightly different points stay where they were gripped.
        public var delta: Double
        public init(key: CableKey, delta: Double) { self.key = key; self.delta = delta }
    }

    public var id: Int
    public var members: [Member]
    public var s: Double          // position along the cable, 0...1
    // Set for ties the sim placed itself (one per fan-out); nil = yours.
    public fileprivate(set) var fanOut: String?
    public fileprivate(set) var center = Vec(0, 0)
    public fileprivate(set) var angle = 0.0    // of the bundle's cross axis
    public fileprivate(set) var width = 0.0
    // How many of its strands it grips right now. Under two, it is dormant:
    // not drawn, not grabbable, and its strands run free.
    public fileprivate(set) var holds = 0
}

public final class CableSim {
    public struct Edge: Sendable, Equatable {
        public var parent: Rect
        public var child: Rect
        public init(parent: Rect, child: Rect) { self.parent = parent; self.child = child }
    }

    public struct Hit: Sendable {
        public var key: CableKey
        public var point: Vec    // nearest spot on the drawn cable
        public var distance: Double
    }

    public static let points = 32
    // Where along the cable a fan-out's tie first sits, nearest first. A
    // tie only goes where its strands are still travelling together.
    private static let fanOutS = [0.35, 0.28]
    private static let fanOutSpread = 48.0
    private static let portSpacing = 10.0
    // Ports stay this share of a side's length away from each corner.
    private static let portInsetShare = 0.15
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
    private static let strandGap = 4.2
    private static let tieThickness = 7.0
    // Half the stretch a bundle runs parallel through its tie, the share
    // of a segment's length its handles reach, and how often a drawn
    // segment is sampled.
    private static let runHalf = 14.0
    private static let handleShare = 0.4
    // A strand must reach a tie within this angle of the bundle's flow
    // (as a cosine): sideways or behind, it would loop back on itself. The
    // handles of a bend that sharp are shortened to this share, at least.
    private static let minTurn = 0.2
    private static let minHandle = 0.35
    private static let sampleEvery = 10.0
    private static let minSamples = 4
    // The margin a tie keeps from the cable ends.
    private static let tieEnds = 7
    private static let edgeMargin = 2.0
    private static let scanStep = 0.1
    private static let tieGap = 40.0
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

    private var edges = [CableKey: Edge]()
    private var calm = 0
    private var nextTie = 1
    // Fan-outs whose tie you removed: the sim leaves them alone.
    private var declined = Set<String>()

    public init() {}

    // MARK: Edges

    public func setEdges(_ edges: [CableKey: Edge]) {
        self.edges = edges
        layoutPorts()
    }

    // Ports follow the ties too: strands a tie holds leave together.
    private func layoutPorts() {
        let ends = Self.ports(edges, ties: ties)

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
        var other: Rect
        var side: Side
    }

    // One port per cable end, on the side facing the other pane, and where
    // along that side gives the straightest cable: level with the other
    // pane when they overlap, else as near as the edge allows. A side with
    // several cables spreads them apart, ordered by where each cable's
    // other end is, so neighbors never cross on the way out.
    private static func ports(_ edges: [CableKey: Edge], ties: [CableTie]) -> [CableKey: (a: CableEnd, b: CableEnd)] {
        var groups = [String: [EndRef]]()
        let pins = Self.pins(edges, ties)

        for key in edges.keys.sorted(by: { $0.order < $1.order }) {
            guard let e = edges[key] else { continue }
            let toward = pins.parent[key] ?? e.child
            let back = pins.child[key] ?? e.parent

            // A tied end picks its side by the whole tie; the other end then
            // takes the opposite side, so a bundle leaves one pane's right
            // and meets each pane's left, whatever the vertical offsets.
            var pSide = side(of: e.parent, facing: toward)
            var cSide = side(of: e.child, facing: back)
            if pins.parent[key] != nil, pins.child[key] == nil { cSide = opposite(pSide) }
            if pins.child[key] != nil, pins.parent[key] == nil { pSide = opposite(cSide) }

            let p = EndRef(key: key, isParent: true, rect: e.parent, other: toward, side: pSide)
            let c = EndRef(key: key, isParent: false, rect: e.child, other: back, side: cSide)
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

    // What a tied strand faces instead of its own other end: where all the
    // tie's strands go. Strands that share a pane at one end (a parent and
    // its children) then leave that pane together, side by side, toward the
    // tie, not each toward its own window. Only ties you made count.
    private static func pins(_ edges: [CableKey: Edge], _ ties: [CableTie])
        -> (parent: [CableKey: Rect], child: [CableKey: Rect]) {
        var parent = [CableKey: Rect](), child = [CableKey: Rect]()

        for t in ties.sorted(by: { $0.id < $1.id }) where t.fanOut == nil {
            let keys = t.members.map(\.key).filter { edges[$0] != nil }
            guard keys.count >= 2 else { continue }

            if Set(keys.map(\.parent)).count == 1 {
                let all = union(keys.compactMap { edges[$0]?.child })
                for k in keys where parent[k] == nil { parent[k] = all }
            }
            if Set(keys.map(\.child)).count == 1 {
                let all = union(keys.compactMap { edges[$0]?.parent })
                for k in keys where child[k] == nil { child[k] = all }
            }
        }
        return (parent, child)
    }

    private static func union(_ rects: [Rect]) -> Rect {
        let x0 = rects.map(\.x).min() ?? 0, y0 = rects.map(\.y).min() ?? 0
        let x1 = rects.map { $0.x + $0.w }.max() ?? 0, y1 = rects.map { $0.y + $0.h }.max() ?? 0
        return Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    private static func groupID(_ r: EndRef) -> String {
        let pane = r.isParent ? r.key.parent : r.key.child
        return "\(pane)\(r.side)"
    }

    private static func place(_ group: [EndRef]) -> [(EndRef, CableEnd)] {
        guard let first = group.first else { return [] }

        let vertical = first.side == .left || first.side == .right
        let r = first.rect
        let (from, to) = vertical ? (r.y, r.y + r.h) : (r.x, r.x + r.w)
        let inset = (to - from) * portInsetShare
        let (lo, hi) = (from + inset, to - inset)

        let wanted = group.map { (ref: $0, at: ideal($0, vertical: vertical, lo: lo, hi: hi)) }
            .sorted { $0.at != $1.at ? $0.at < $1.at : $0.ref.key.order < $1.ref.key.order }
        let at = spread(wanted.map(\.at), lo: lo, hi: hi)

        return zip(wanted, at).map { w, t in
            switch w.ref.side {
            case .right: return (w.ref, CableEnd(point: Vec(r.x + r.w, t), normal: Vec(1, 0)))
            case .left: return (w.ref, CableEnd(point: Vec(r.x, t), normal: Vec(-1, 0)))
            case .top: return (w.ref, CableEnd(point: Vec(t, r.y + r.h), normal: Vec(0, 1)))
            case .bottom: return (w.ref, CableEnd(point: Vec(t, r.y), normal: Vec(0, -1)))
            }
        }
    }

    // Where along the edge (lo...hi) this cable wants to leave: the middle
    // of the stretch the two panes share, else toward the other pane.
    private static func ideal(_ ref: EndRef, vertical: Bool, lo: Double, hi: Double) -> Double {
        let (r, o) = (ref.rect, ref.other)
        let (a0, a1, b0, b1) = vertical ? (r.y, r.y + r.h, o.y, o.y + o.h) : (r.x, r.x + r.w, o.x, o.x + o.w)

        let shared = (max(a0, b0), min(a1, b1))
        let want = shared.0 < shared.1 ? (shared.0 + shared.1) / 2 : (b0 + b1) / 2
        return min(max(want, lo), hi)
    }

    // Sorted spots pushed apart to `portSpacing` (less if the edge is
    // short), kept inside lo...hi. A crowd spreads evenly around where it
    // wanted to be: the average of pushing everyone up and pushing everyone
    // down, which keeps every gap.
    private static func spread(_ at: [Double], lo: Double, hi: Double) -> [Double] {
        guard at.count > 1 else { return at }

        let gap = min(portSpacing, (hi - lo) / Double(at.count - 1))
        var up = at, down = at
        for i in 1..<at.count { up[i] = max(up[i], up[i - 1] + gap) }
        for i in stride(from: at.count - 2, through: 0, by: -1) { down[i] = min(down[i], down[i + 1] - gap) }

        var out = zip(up, down).map { ($0 + $1) / 2 }
        let over = max((out.last ?? hi) - hi, 0)
        let under = max(lo - (out.first ?? lo), 0)
        out = out.map { $0 - over + under }
        return out
    }

    private static func opposite(_ s: Side) -> Side {
        switch s {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    // Which side of `r` faces `o` (y grows up): across the wider gap when
    // they are apart, else toward its center.
    private static func side(of r: Rect, facing o: Rect) -> Side {
        let gapX = max(o.x - (r.x + r.w), r.x - (o.x + o.w))
        let gapY = max(o.y - (r.y + r.h), r.y - (o.y + o.h))
        let (c, oc) = (center(r), center(o))

        // Apart on an axis: leave across the wider gap.
        if gapX > 0 || gapY > 0 {
            if gapX >= gapY { return oc.x >= c.x ? .right : .left }
            return oc.y >= c.y ? .top : .bottom
        }

        let dx = (oc.x - c.x) / max(r.w, 1), dy = (oc.y - c.y) / max(r.h, 1)
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
            c.free = Self.sample(c.a, c.b, c.h1, c.h2)
            c.pts = c.free
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

    // Fractional point index where the tie at `s` grips member `m`.
    private func place(_ t: CableTie, _ m: CableTie.Member, at s: Double? = nil) -> Double {
        let f = (s ?? t.s) * Double(Self.points - 1) + m.delta
        return min(max(f, Self.edgeMargin), Double(Self.points - 1) - Self.edgeMargin)
    }

    // The polyline at fractional index `f`.
    private static func at(_ pts: [Vec], _ f: Double) -> Vec {
        let g = min(max(f, 0), Double(pts.count - 1))
        let i = min(Int(g), pts.count - 2)
        return pts[i] + (pts[i + 1] - pts[i]) * (g - Double(i))
    }

    private static func mean(_ v: [Vec]) -> Vec {
        let sum = v.reduce(Vec(0, 0), +)
        return sum * (1 / Double(max(v.count, 1)))
    }

    // The strands the tie can hold at `s`: those that pass it heading the
    // way the bundle flows. One that would have to double back through the
    // tie (a loop) is not held. The bundle's direction is the one the most
    // strands agree on.
    private func holders(_ t: CableTie, at s: Double? = nil) -> [CableTie.Member] {
        let live = t.members.filter { cables[$0.key] != nil }
        guard live.count >= 2 else { return live }

        let ends = live.map { (a: cables[$0.key]!.a.point, b: cables[$0.key]!.b.point) }
        let mid = live.map { Self.at(cables[$0.key]!.free, place(t, $0, at: s)) }
        var best = [Int]()

        for lead in live.indices {
            let ref = ends[lead].b - ends[lead].a
            var flow = Vec(0, 0)
            var way = [Double]()
            for e in ends {
                let run = e.b - e.a
                way.append(run.dot(ref) < 0 ? -1 : 1)
                flow = flow + run * way.last!
            }
            guard flow.length > 1e-6 else { continue }
            let u = flow * (1 / flow.length)

            // Judged against where the held strands meet, so the one that
            // doesn't belong can't drag the center toward itself.
            var held = Array(live.indices)
            for _ in 0..<2 {
                let center = Self.mean(held.map { mid[$0] })
                held = held.filter { i in
                    let (before, after) = way[i] > 0 ? (ends[i].a, ends[i].b) : (ends[i].b, ends[i].a)
                    let (toward, away) = (center - before, after - center)
                    return toward.dot(u) > Self.minTurn * toward.length && away.dot(u) > Self.minTurn * away.length
                }
                if held.isEmpty { break }
            }
            if held.count > best.count { best = held }
        }
        return best.map { live[$0] }
    }

    // Where one tie sits and how its strands pass it.
    private struct Spot {
        var keys: [CableKey]
        var f: [CableKey: Double] = [:]       // point index on each free curve
        var center = Vec(0, 0)
        var flow = Vec(1, 0)                  // unit, port a -> port b
        var way: [CableKey: Double] = [:]     // +1, or -1 for a strand running b -> a
        var before: [CableKey: Vec] = [:]     // where each strand comes from, and goes next
        var after: [CableKey: Vec] = [:]
        var slot: [CableKey: Double] = [:]    // offset across the bundle
        var cross: Vec { Vec(-flow.y, flow.x) }
    }

    private struct Layout {
        var spots: [Int: Spot] = [:]
        var chains: [CableKey: [Int]] = [:]   // tie ids along each cable, a -> b
    }

    // Work out every tie: its center (the mean of where its strands would
    // run), the direction the bundle flows (from the spots just before the
    // strands to just after: the neighboring tie, or the port), and each
    // strand's slot across it. Also keeps the pills' own numbers current.
    private func layout() -> Layout {
        var out = Layout()

        for t in ties {
            let live = holders(t)
            guard live.count >= 2 else { continue }

            var spot = Spot(keys: live.map(\.key))
            for m in live { spot.f[m.key] = place(t, m) }
            spot.center = Self.mean(live.map { Self.at(cables[$0.key]!.free, spot.f[$0.key]!) })
            out.spots[t.id] = spot
            for m in live { out.chains[m.key, default: []].append(t.id) }
        }

        for key in out.chains.keys {
            out.chains[key]!.sort { out.spots[$0]!.f[key]! < out.spots[$1]!.f[key]! }
        }

        // A strand the bundle's flow would send backwards is let go; the
        // flow is then worked out again for those left.
        for id in out.spots.keys.sorted() {
            var spot = out.spots[id]!
            flow(&spot, id, out)

            let strays = spot.keys.filter { stray($0, spot) }
            if !strays.isEmpty {
                release(strays, id, &spot, &out)
                if spot.keys.count >= 2 { flow(&spot, id, out) }
            }
            out.spots[id] = spot.keys.count >= 2 ? spot : nil
            if spot.keys.count < 2 { release(spot.keys, id, &spot, &out) }
        }

        for i in ties.indices {
            guard let spot = out.spots[ties[i].id] else {
                ties[i].holds = 0
                continue
            }
            ties[i].holds = spot.keys.count
            ties[i].center = spot.center
            ties[i].angle = atan2(spot.cross.y, spot.cross.x)
            ties[i].width = Double(spot.keys.count - 1) * Self.strandGap + Self.tieThickness
        }
        return out
    }

    // Does `key` reach the tie sideways or from behind the bundle's flow?
    private func stray(_ key: CableKey, _ spot: Spot) -> Bool {
        let dir = spot.flow * spot.way[key]!
        let (toward, away) = (spot.center - spot.before[key]!, spot.after[key]! - spot.center)
        return toward.dot(dir) <= Self.minTurn * toward.length || away.dot(dir) <= Self.minTurn * away.length
    }

    private func release(_ keys: [CableKey], _ id: Int, _ spot: inout Spot, _ out: inout Layout) {
        for key in keys {
            out.chains[key]?.removeAll { $0 == id }
        }
        spot.keys.removeAll { keys.contains($0) }
        guard !spot.keys.isEmpty else { return }

        spot.center = Self.mean(spot.keys.map { Self.at(cables[$0]!.free, spot.f[$0]!) })
    }

    private func flow(_ spot: inout Spot, _ id: Int, _ out: Layout) {
        var runs = [CableKey: Vec]()
        for key in spot.keys {
            let chain = out.chains[key]!
            let k = chain.firstIndex(of: id)!
            let c = cables[key]!
            let before = k > 0 ? out.spots[chain[k - 1]]!.center : c.a.point
            let after = k + 1 < chain.count ? out.spots[chain[k + 1]]!.center : c.b.point
            runs[key] = after - before
            spot.before[key] = before
            spot.after[key] = after
        }

        // Strands running the opposite way are flipped so they don't cancel.
        let lead = runs[spot.keys[0]]!
        var sum = Vec(0, 0)
        for key in spot.keys {
            let way = runs[key]!.dot(lead) < 0 ? -1.0 : 1.0
            spot.way[key] = way
            sum = sum + runs[key]! * way
        }
        if sum.length > 1e-6 { spot.flow = sum * (1 / sum.length) }

        // Slots follow the strands' order across the bundle.
        let cross = spot.cross
        let across = spot.keys.map { ($0, (Self.at(cables[$0]!.free, spot.f[$0]!) - spot.center).dot(cross)) }
        let order = across.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.order < $1.0.order }
        for (rank, item) in order.enumerated() {
            spot.slot[item.0] = (Double(rank) - Double(order.count - 1) / 2) * Self.strandGap
        }
    }

    // Re-draw every tied cable as smooth curves through its ties: the port,
    // then for each tie a short parallel run, then the other port. Handles
    // at a tie point along the bundle; at a port they are the sprung
    // handle (scaled to the stretch), so the swing still shows.
    private func bundleTies() {
        let lay = layout()

        for (key, chain) in lay.chains {
            guard var c = cables[key] else { continue }

            var knots = [(p: Vec, dir: Vec?)]()
            knots.append((c.a.point, nil))
            for id in chain {
                let spot = lay.spots[id]!
                let dir = spot.flow * spot.way[key]!
                let at = spot.center + spot.cross * spot.slot[key]!
                knots.append((at - dir * Self.runHalf, dir))
                knots.append((at + dir * Self.runHalf, dir))
            }
            knots.append((c.b.point, nil))

            c.pts = Self.draw(knots, c)
            cables[key] = c
        }
    }

    private static func draw(_ knots: [(p: Vec, dir: Vec?)], _ c: Cable) -> [Vec] {
        let span = max((c.b.point - c.a.point).length, 1)
        var out = [Vec]()

        for j in 0..<(knots.count - 1) {
            let (p, q) = (knots[j], knots[j + 1])
            let chord = (q.p - p.p).length
            let share = min(max(chord / span, 0.25), 1)

            // A handle shortens as its strand turns away from the bundle.
            func reach(_ dir: Vec) -> Double {
                let along = chord > 1e-6 ? dir.dot(q.p - p.p) / chord : 1
                return chord * handleShare * min(max(along, minHandle), 1)
            }
            let c1 = p.dir.map { p.p + $0 * reach($0) } ?? p.p + (c.h1 - c.a.point) * share
            let c2 = q.dir.map { q.p - $0 * reach($0) } ?? q.p + (c.h2 - c.b.point) * share

            let n = max(minSamples, Int(chord / sampleEvery))
            for i in (j == 0 ? 0 : 1)...n {
                out.append(bezier(p.p, c1, c2, q.p, Double(i) / Double(n)))
            }
        }
        return out
    }

    private func refreshTies() {
        _ = layout()
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
                best = Hit(key: key, point: c.pts[i] + (c.pts[i + 1] - c.pts[i]) * h.t, distance: h.gap)
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
        return ties.filter { $0.holds >= 2 && hit($0) }.min { ($0.center - p).length < ($1.center - p).length }?.id
    }

    // A tie around every strand the stroke a -> b crosses (or touches).
    // Nil unless it meets two or more: one strand has nothing to bundle.
    // A spot too near the ends or another tie slides to the nearest free one.
    @discardableResult
    public func addTie(from a: Vec, to b: Vec, radius: Double? = nil) -> Int? {
        let found = hits(along: a, to: b, radius: radius ?? Self.bundleRadius)
        guard found.count >= 2, let lead = found.min(by: { $0.distance < $1.distance }) else { return nil }

        // Each strand is gripped where the stroke met it, on its free curve.
        func index(_ h: Hit) -> Double { Self.along(cables[h.key]!.free, h.point) }
        let f0 = index(lead)

        let members = found.map { CableTie.Member(key: $0.key, delta: index($0) - f0) }
        var tie = CableTie(id: nextTie, members: members, s: f0 / Double(Self.points - 1))
        guard let s = clear(tie, at: tie.s) else { return nil }

        // Strands that would loop through the spot are left out.
        tie.s = s
        let held = holders(tie)
        guard held.count >= 2 else { return nil }

        tie.members = held
        nextTie += 1
        ties.append(tie)
        layoutPorts()
        wake()
        refreshTies()
        return tie.id
    }

    // A tie from saved state: nil unless two or more of its cables exist
    // and a free spot is left. No hit-testing: the strands are named.
    @discardableResult
    public func restoreTie(_ members: [CableTie.Member], s: Double) -> Int? {
        let live = members.filter { cables[$0.key] != nil }
        guard live.count >= 2 else { return nil }

        var tie = CableTie(id: nextTie, members: live, s: s)
        guard let at = clear(tie, at: s) else { return nil }

        tie.s = at
        nextTie += 1
        ties.append(tie)
        layoutPorts()
        wake()
        refreshTies()
        return tie.id
    }

    // Put a tie at `s` (0...1) outright, as when something else moved it.
    public func slideTie(_ id: Int, to s: Double) {
        guard let i = ties.firstIndex(where: { $0.id == id }),
              let at = clear(ties[i], at: s) else { return }

        ties[i].s = at
        wake()
        refreshTies()
    }

    public func removeTie(_ id: Int) {
        guard let t = ties.first(where: { $0.id == id }) else { return }
        if let fan = t.fanOut { declined.insert(fan) }
        ties.removeAll { $0.id == id }
        layoutPorts()
        wake()
    }

    // Slide a tie toward `p`, along its cable. It stops at the ends and at
    // its neighbors on any shared cable: ties never pass or overlap.
    public func moveTie(_ id: Int, to p: Vec) {
        guard let i = ties.firstIndex(where: { $0.id == id }) else { return }

        // The spot whose bundle center is nearest the pointer: the tie
        // follows the mouse, however far apart its strands are.
        var best: (s: Double, d: Double)?
        let length = Double(Self.points - 1)
        let keep = max(2, ties[i].holds)

        for f in stride(from: 0.0, through: length, by: Self.scanStep) {
            guard let s = clear(ties[i], at: f / length),
                  holders(ties[i], at: s).count >= keep,
                  let c = center(ties[i], at: s) else { continue }

            let d = (c - p).length
            if d < (best?.d ?? .infinity) { best = (s, d) }
        }
        guard let best else { return }

        ties[i].s = best.s
        wake()
        refreshTies()
    }

    // Where the tie's strands run at `s`, on average.
    private func center(_ t: CableTie, at s: Double) -> Vec? {
        let at = t.members.compactMap { m in
            cables[m.key].map { Self.at($0.free, place(t, m, at: s)) }
        }
        return at.isEmpty ? nil : Self.mean(at)
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
