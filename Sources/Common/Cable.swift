// Cables between panes that spawned each other: ropes under gravity, with ties.
//
//        ┌────────┐                                   ┌────────┐
//        │ parent ◎─╮      ┌───────────┐          ╭───◎ child  │
//        └────────┘ ╰╮ ●●●●┤ any pane  ├●●●●    ╭─╯   └────────┘
//          reel (◎)   ╰●●  │           │   ●●═●●╯
//                          └───────────┘     tie (a reel too)
//
//   rope    a chain of beads (Verlet), links held to length, falling under
//           gravity, a little stiff, heavily damped. It starts at the
//           center of each pane, under it; the two beads at each end are
//           held, aimed at the side it leaves by.
//   reels   the rope is split at its ties into stretches, window or tie to
//           tie or window. The upstream end of each is a reel: it winds in
//           until the stretch is `slack` past a straight line, and pays out
//           only when its ends move apart. No spare rope, no loops.
//   panes   every other pane is solid: the rope drapes over tops, catches
//           on corners, rests against sides. Pushed into, the rope can only
//           stretch (the reels give nothing); past maxStretch it gives up on
//           that pane and passes through it (a ghost) until it is clear.
//   ports   a pane's cables start a few points apart at its center, in the
//           order they leave, so strands leave uncrossed.
//   tie     fixed at its spot (`s` along its strands' straight runs, on
//           average), holding each strand in a slot across the bundle.
//           Ties on a shared cable keep their order and a gap.
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
    // What you see: the rope's beads, port a to port b.
    public fileprivate(set) var pts: [Vec]
    // Each bead a substep ago: Verlet keeps velocity as the gap.
    fileprivate var prev: [Vec]
    // Rope in each stretch, a -> b, split at its ties (`chain`, by id):
    // each stretch is wound by its own reel, at the port or tie upstream.
    fileprivate var spans: [Double]
    fileprivate var chain = [Int]()
    // Panes the rope passes through instead of draping over.
    fileprivate var ghosts = Set<PaneID>()

    // Unstretched, port to port.
    fileprivate var length: Double { spans.reduce(0, +) }
}

public struct CableTie: Sendable {
    public struct Member: Sendable {
        public var key: CableKey
        // Older builds' grip offset, in beads off `s`: restoreTie folds it
        // into `s`. New ties keep 0.
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

    public static let points = 48
    // Where along the cable a fan-out's tie first sits, nearest first. A
    // tie only goes where its strands are still travelling together.
    private static let fanOutS = [0.35, 0.28]
    private static let fanOutSpread = 48.0
    private static let portSpacing = 10.0
    private static let epsilon = 1e-6
    // Ports stay this share of a side's length away from each corner.
    private static let portInsetShare = 0.15
    // Rope: gravity (points/s², y grows up), drag (per second), and how
    // much longer than the straight line between its ports it is.
    private static let gravity = Vec(0, -2400)
    private static let drag = 8.0
    // Share of each bead's speed traded with its neighbors' every substep:
    // waves along the cable die (no twang) while it still swings whole.
    private static let viscosity = 0.3
    // Reels: each stretch is wound in at reelSpeed (points/s) until it is
    // `slack` past the straight line, plus minSlack; pulled, it pays out
    // at once. Never more rope than that hanging around to loop.
    public static let defaultSlack = 0.06
    private static let minSlack = 12.0
    private static let reelSpeed = 600.0
    // Share of a fold undone per pass: a cable, not a string.
    private static let stiffness = 0.12
    // One display frame: substeps of integrate, then relax the links,
    // ties, and panes this many times. Fixed: same input, same motion.
    private static let dt = 1.0 / 60
    private static let substeps = 6
    private static let iterations = 10
    // Beads held at each end: the port, and one just out of it.
    private static let held = 2
    // How far off a pane the rope rests (about half its drawn width), the
    // share of its slide a pane's surface takes each substep, and how far
    // it stretches against panes before passing through the hardest one.
    private static let radius = 2.0
    private static let friction = 0.4
    private static let maxStretch = 0.1
    // A pane the rope runs through counts if it is this far inside, so a
    // port on the pane's own edge is not "through" it.
    private static let inside = 0.5
    // The rope's first shape, before gravity takes it: hanging handles,
    // this share of the cable's length below the straight pull, at most.
    private static let sagShare = 0.05
    private static let maxSag = 36.0
    private static let strandGap = 4.2
    private static let tieThickness = 7.0
    // A strand must reach a tie within this angle of the bundle's flow
    // (as a cosine): sideways or behind, it would loop back on itself.
    private static let minTurn = 0.12
    // The margin a tie keeps from the cable ends.
    private static let tieEnds = 10
    private static let edgeMargin = 3.0
    private static let scanStep = 0.1
    private static let tieGap = 40.0
    private static let bundleRadius = 12.0
    // Asleep after this many frames with no bead moving calmMove a substep.
    private static let calmMove = 0.02
    private static let calmFrames = 30
    private static let moved = 0.01

    public private(set) var cables = [CableKey: Cable]()
    public private(set) var ties = [CableTie]()
    public private(set) var isAwake = false

    private var edges = [CableKey: Edge]()
    private var panes = [PaneID: Rect]()
    private var slack = defaultSlack
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

    // A new rope starts as a ghost to every pane it lies across, or the
    // first step would fling it clear.
    private func update(_ key: CableKey, a: CableEnd, b: CableEnd) {
        guard var c = cables[key] else {
            var c = Self.make(a: a, b: b)
            c.ghosts = Self.crossed(key, c.pts, panes)
            cables[key] = c
            wake()
            return
        }
        guard !Self.same(c.a, a) || !Self.same(c.b, b) else { return }

        c.a = a
        c.b = b
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

    // How far past a straight line the reels let each stretch hang.
    public func setSlack(_ slack: Double) {
        guard slack != self.slack else { return }

        self.slack = slack
        wake()
    }

    // MARK: Panes

    // Every pane on the canvas: what the ropes drape over. A pane that
    // opens on top of a rope starts as a ghost to it, same as a new rope.
    // Only a pane that came, went, or moved within reach of a rope (where
    // it was, or where it is) wakes the sim: dragging one far off is free.
    public func setPanes(_ panes: [PaneID: Rect]) {
        guard panes != self.panes else { return }

        var changed = panes.filter { self.panes[$0.key] != $0.value }.map(\.value)
        changed += self.panes.filter { panes[$0.key] != $0.value }.map(\.value)

        let fresh = panes.filter { self.panes[$0.key] == nil }
        self.panes = panes
        for key in cables.keys {
            cables[key]!.ghosts.formUnion(Self.crossed(key, cables[key]!.pts, fresh))
        }

        let near = cables.values.contains { c in changed.contains { Self.overlap(Self.box(c), $0) } }
        if near {
            wake()
        }
    }

    // Panes some stretch of the rope runs through, bar its own two: it
    // starts under those.
    private static func crossed(_ key: CableKey, _ pts: [Vec], _ panes: [PaneID: Rect]) -> Set<PaneID> {
        Set(panes.filter { $0.key != key.parent && $0.key != key.child && enters(pts, $0.value) }.map(\.key))
    }

    private static func enters(_ pts: [Vec], _ r: Rect) -> Bool {
        let core = grow(r, by: -inside)
        return zip(pts, pts.dropFirst()).contains { cuts($0, $1, core) }
    }

    // Does the segment p-q pass inside r?
    private static func cuts(_ p: Vec, _ q: Vec, _ r: Rect) -> Bool {
        clip(p, q, r) != nil
    }

    // The stretch of p-q inside r, as 0...1 along it. Clips one axis at a
    // time (Liang-Barsky): what is left of 0...1 after both is inside.
    // Hot: runs per link, per pane, per pass. No arrays.
    private static func clip(_ p: Vec, _ q: Vec, _ r: Rect) -> (Double, Double)? {
        let d = q - p
        var span = (0.0, 1.0)

        guard narrow(&span, d.x, p.x, r.x, r.x + r.w),
              narrow(&span, d.y, p.y, r.y, r.y + r.h) else { return nil }
        return span
    }

    // One axis of clip: `span` cut to where from + step * t is in lo...hi.
    // False once nothing is left.
    private static func narrow(_ span: inout (Double, Double), _ step: Double,
                               _ from: Double, _ lo: Double, _ hi: Double) -> Bool {
        if abs(step) < epsilon {
            return from > lo && from < hi
        }

        let (u, v) = ((lo - from) / step, (hi - from) / step)
        span.0 = max(span.0, min(u, v))
        span.1 = min(span.1, max(u, v))
        return span.0 < span.1
    }

    private static func grow(_ r: Rect, by d: Double) -> Rect {
        Rect(x: r.x - d, y: r.y - d, w: r.w + 2 * d, h: r.h + 2 * d)
    }

    private static func overlap(_ a: Rect, _ b: Rect) -> Bool {
        a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
    }

    // MARK: Ports

    private enum Side { case left, right, top, bottom }

    private struct EndRef {
        var key: CableKey
        var isParent: Bool
        var rect: Rect
        var other: Rect
        var side: Side
        var target: Vec    // where this cable's own other end is
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

            let p = EndRef(key: key, isParent: true, rect: e.parent, other: toward, side: pSide,
                           target: center(e.child))
            let c = EndRef(key: key, isParent: false, rect: e.child, other: back, side: cSide,
                           target: center(e.parent))
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

        // Ties in `ideal` (a tied bundle all faces one spot) go by where each
        // cable's own end is, so the strands leave in the order they end.
        let wanted = group.map { (ref: $0, at: ideal($0, vertical: vertical, lo: lo, hi: hi)) }
            .sorted {
                if abs($0.at - $1.at) > epsilon { return $0.at < $1.at }
                let (p, q) = vertical ? ($0.ref.target.y, $1.ref.target.y) : ($0.ref.target.x, $1.ref.target.x)
                return p != q ? p < q : $0.ref.key.order < $1.ref.key.order
            }
        // Every cable starts at the pane's center (under the pane, out of
        // sight), the side's cables a port apart in the order they leave.
        let mid = center(r)
        let spacing = (0..<wanted.count).map { (Double($0) - Double(wanted.count - 1) / 2) * portSpacing }

        return zip(wanted, spacing).map { w, d in
            switch w.ref.side {
            case .right: return (w.ref, CableEnd(point: mid + Vec(0, d), normal: Vec(1, 0)))
            case .left: return (w.ref, CableEnd(point: mid + Vec(0, d), normal: Vec(-1, 0)))
            case .top: return (w.ref, CableEnd(point: mid + Vec(d, 0), normal: Vec(0, 1)))
            case .bottom: return (w.ref, CableEnd(point: mid + Vec(d, 0), normal: Vec(0, -1)))
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

    // Laid out along the resting curve, still, then left to fall; the
    // reels take up whatever it has too much of.
    private static func make(a: CableEnd, b: CableEnd) -> Cable {
        let (r1, r2) = rest(a, b)
        let pts = sample(a, b, r1, r2)
        return Cable(a: a, b: b, pts: pts, prev: pts, spans: [length(pts)])
    }

    // MARK: Step

    // One display frame. Each substep: every bead coasts and falls, then
    // the links, ties, and panes are satisfied in turn, panes last so the
    // rope never ends a step inside one. Same input, same motion.
    public func step() {
        guard isAwake else { return }

        var lay = layout()
        let keys = Array(cables.keys)
        let h = Self.dt / Double(Self.substeps)
        var worst = 0.0

        for key in keys {
            reel(key, &lay)
        }

        for _ in 0..<Self.substeps {
            var near = [CableKey: [(PaneID, Rect)]]()
            for key in keys {
                worst = max(worst, Self.integrate(&cables[key]!, h))
                near[key] = solids(key, cables[key]!)
            }

            var pushed = [CableKey: [PaneID: Double]]()
            var touched = [CableKey: [Int: Side]]()
            for pass in 0..<Self.iterations {
                for key in keys {
                    Self.links(&cables[key]!, pass.isMultiple(of: 2) ? .forward : .backward)
                }
                grip(lay)
                for key in keys {
                    Self.collide(&cables[key]!, near[key]!, &pushed[key, default: [:]], &touched[key, default: [:]])
                }
            }

            for key in keys {
                Self.settle(&cables[key]!, touched[key] ?? [:])
                Self.give(&cables[key]!, pushed[key] ?? [:])
            }
        }

        for key in keys {
            cables[key]!.ghosts = cables[key]!.ghosts.filter { id in
                panes[id].map { Self.enters(cables[key]!.pts, $0) } ?? false
            }
        }
        refreshTies()

        calm = worst < Self.calmMove ? calm + 1 : 0
        if calm >= Self.calmFrames { isAwake = false }
    }

    private static func isHeld(_ i: Int) -> Bool { i < held || i >= points - held }

    // One frame of the cable's reels. Each stretch (port or tie to the next
    // tie or port) winds in toward `slack` past its straight line, and pays
    // out only when that line grows: an end moved. A pane pushing into the
    // rope earns it nothing, so it stretches (and past maxStretch, passes
    // through). Then each tie grips the cable where the rope before it
    // runs out:
    //
    //   port ──120──▶ tie ──300──▶ tie ──180──▶ port   (600 of rope, 47 links)
    //                 bead 9.4     bead 32.9
    private func reel(_ key: CableKey, _ lay: inout Layout) {
        var c = cables[key]!
        let chain = lay.chains[key] ?? []

        // New ties (or one gone): split the rope where the ties sit now.
        if chain != c.chain {
            let cuts = [0] + chain.map { lay.spots[$0]!.f[key]! } + [Double(Self.points - 1)]
            c.spans = zip(cuts, cuts.dropFirst()).map { Self.arc(c.pts, from: $0, to: $1) }
            c.chain = chain
        }

        let stops = [c.a.point] + chain.map { lay.spots[$0]!.center } + [c.b.point]
        for k in c.spans.indices {
            let want = (stops[k + 1] - stops[k]).length * (1 + slack) + Self.minSlack
            c.spans[k] = max(want, c.spans[k] - Self.reelSpeed * Self.dt)
        }

        var run = 0.0
        let (n, total) = (Double(Self.points - 1), max(c.length, Self.epsilon))
        for (k, id) in chain.enumerated() {
            run += c.spans[k]
            lay.spots[id]!.f[key] = min(max(n * run / total, Self.edgeMargin), n - Self.edgeMargin)
        }
        cables[key] = c
    }

    // Rope along the beads between fractional indexes `from` and `to`.
    private static func arc(_ pts: [Vec], from: Double, to: Double) -> Double {
        let inner = pts.indices.filter { Double($0) > from && Double($0) < to }.map { pts[$0] }
        return length([at(pts, from)] + inner + [at(pts, to)])
    }

    // Verlet: each bead keeps going the way it went (less drag, and blended
    // with its neighbors: viscosity) and falls. Returns the fastest step.
    private static func integrate(_ c: inout Cable, _ h: Double) -> Double {
        let keep = 1 - drag * h
        let v = zip(c.pts, c.prev).map { $0 - $1 }
        var worst = 0.0

        for i in held..<(points - held) {
            let shared = (v[i - 1] + v[i + 1]) * 0.5
            let step = (v[i] * (1 - viscosity) + shared * viscosity) * keep
            worst = max(worst, step.length)
            c.prev[i] = c.pts[i]
            c.pts[i] = c.pts[i] + step + gravity * (h * h)
        }
        pin(&c)
        return worst
    }

    // The held beads: on the port, and one link out of it, square to the
    // pane edge, so the rope leaves the way a plug does.
    private static func pin(_ c: inout Cable) {
        let seg = c.length / Double(points - 1)
        let n = points

        c.pts[0] = c.a.point
        c.pts[1] = c.a.point + c.a.normal * seg
        c.pts[n - 1] = c.b.point
        c.pts[n - 2] = c.b.point + c.b.normal * seg
        for i in [0, 1, n - 2, n - 1] {
            c.prev[i] = c.pts[i]
        }
    }

    private enum Sweep { case forward, backward }

    // Every link back to its length, then every fold eased open a little
    // (bead i to i+2: the cable's stiffness). Sweeps alternate, so a tug
    // at either end travels the whole cable in one pass.
    private static func links(_ c: inout Cable, _ sweep: Sweep) {
        let seg = c.length / Double(points - 1)

        for k in 0..<(points - 1) {
            let i = sweep == .forward ? k : points - 2 - k
            pull(&c, i, i + 1, to: seg, share: 1)
        }
        for i in 0..<(points - 2) {
            pull(&c, i, i + 2, to: 2 * seg, share: stiffness)
        }
    }

    // Beads i and j `share` of the way back to `rest` apart, split between
    // them; a held bead does not budge.
    private static func pull(_ c: inout Cable, _ i: Int, _ j: Int, to rest: Double, share: Double) {
        let (wa, wb) = (isHeld(i) ? 0.0 : 1.0, isHeld(j) ? 0.0 : 1.0)
        let d = c.pts[j] - c.pts[i]
        let len = d.length
        guard wa + wb > 0, len > epsilon else { return }

        let fix = d * ((len - rest) / len / (wa + wb) * share)
        c.pts[i] = c.pts[i] + fix * wa
        c.pts[j] = c.pts[j] - fix * wb
    }

    // The panes this rope could touch this substep, grown by its radius.
    // Ghosts are left out: the rope passes through those. So are its own
    // two panes: it starts at their centers, under them.
    private func solids(_ key: CableKey, _ c: Cable) -> [(PaneID, Rect)] {
        let box = Self.box(c)
        let own: Set = [key.parent, key.child]

        return panes
            .filter { !own.contains($0.key) && !c.ghosts.contains($0.key) && Self.overlap(box, $0.value) }
            .map { ($0.key, Self.grow($0.value, by: Self.radius)) }
    }

    // What the rope could touch: its beads' bounds, grown by a link and
    // its radius.
    private static func box(_ c: Cable) -> Rect {
        let reach = c.length / Double(points - 1) + radius
        let xs = c.pts.map(\.x), ys = c.pts.map(\.y)
        let (x0, y0) = (xs.min() ?? 0, ys.min() ?? 0)
        return grow(Rect(x: x0, y: y0, w: (xs.max() ?? 0) - x0, h: (ys.max() ?? 0) - y0), by: reach)
    }

    // A bead inside a pane goes back out the side it came in by (else the
    // nearest). Notes how deep each pane pushed, and which side each bead
    // ended against.
    private static func collide(_ c: inout Cable, _ solids: [(PaneID, Rect)],
                                _ pushed: inout [PaneID: Double], _ touched: inout [Int: Side]) {
        for i in held..<(points - held) {
            for (id, r) in solids {
                guard let side = face(c.pts[i], was: c.prev[i], r) else { continue }

                let (p, depth) = out(c.pts[i], side, r)
                c.pts[i] = p
                pushed[id] = max(pushed[id] ?? 0, depth)
                touched[i] = side
            }
        }
        corners(&c, solids, &pushed)
    }

    // Beads outside can still have the link between them cut a corner:
    // the middle of the cut goes out the nearest side, beads following.
    //
    //   bead ●───────●            ●────────●
    //          ╲ ┌───────     →    ╲┌───────
    //        ●  ╲│                ● │
    private static func corners(_ c: inout Cable, _ solids: [(PaneID, Rect)], _ pushed: inout [PaneID: Double]) {
        for i in 0..<(points - 1) {
            for (id, r) in solids {
                guard let (t0, t1) = clip(c.pts[i], c.pts[i + 1], r) else { continue }

                let t = (t0 + t1) / 2
                let m = c.pts[i] + (c.pts[i + 1] - c.pts[i]) * t
                guard let side = face(m, was: m, r) else { continue }

                let (p, depth) = out(m, side, r)
                nudge(&c, Double(i) + t, by: p - m)
                pushed[id] = max(pushed[id] ?? 0, depth)
            }
        }
    }

    // Which side of `r` the bead at `p` (last at `was`) leaves by, if it is
    // inside. Above the top before: the top, so a rope falling on a pane
    // drapes over it rather than squirting out a side.
    private static func face(_ p: Vec, was: Vec, _ r: Rect) -> Side? {
        let (x1, y1) = (r.x + r.w, r.y + r.h)
        guard p.x > r.x, p.x < x1, p.y > r.y, p.y < y1 else { return nil }

        if was.y >= y1 { return .top }
        if was.y <= r.y { return .bottom }
        if was.x <= r.x { return .left }
        if was.x >= x1 { return .right }

        let gaps: [(Side, Double)] = [(.top, y1 - p.y), (.bottom, p.y - r.y), (.left, p.x - r.x), (.right, x1 - p.x)]
        return gaps.min { $0.1 < $1.1 }?.0
    }

    // `p` moved out onto `side` of `r`, and how far it went.
    private static func out(_ p: Vec, _ side: Side, _ r: Rect) -> (Vec, Double) {
        switch side {
        case .top: return (Vec(p.x, r.y + r.h), r.y + r.h - p.y)
        case .bottom: return (Vec(p.x, r.y), p.y - r.y)
        case .left: return (Vec(r.x, p.y), p.x - r.x)
        case .right: return (Vec(r.x + r.w, p.y), r.x + r.w - p.x)
        }
    }

    // A bead that ended against a pane loses its speed into it, and some
    // of its slide along it: ropes rest on panes instead of bouncing.
    private static func settle(_ c: inout Cable, _ touched: [Int: Side]) {
        for (i, side) in touched {
            let v = c.pts[i] - c.prev[i]
            switch side {
            case .top, .bottom: c.prev[i] = c.pts[i] - Vec(v.x * (1 - friction), 0)
            case .left, .right: c.prev[i] = c.pts[i] - Vec(0, v.y * (1 - friction))
            }
        }
    }

    // Stretched past maxStretch against panes, the rope gives up on the
    // one that pushed hardest and passes through it until it is clear.
    private static func give(_ c: inout Cable, _ pushed: [PaneID: Double]) {
        guard length(c.pts) > c.length * (1 + maxStretch),
              let hardest = pushed.max(by: { $0.value < $1.value })?.key else { return }

        c.ghosts.insert(hardest)
    }

    // MARK: Ties

    // Fractional bead index where the tie at `s` would grip member `m`, by
    // distance: port 200 from the tie, far end 800, bead 0.2 of the way.
    // A first guess (which strands it can hold, where a new tie cuts the
    // rope); once tied, the reels decide (see reel).
    private func place(_ t: CableTie, _ m: CableTie.Member, at s: Double? = nil) -> Double {
        let n = Double(Self.points - 1)
        guard let c = cables[m.key] else { return (s ?? t.s) * n }

        let hub = anchor(t.members.map(\.key), at: s ?? t.s)
        let (near, far) = ((hub - c.a.point).length, (c.b.point - hub).length)
        let f = n * near / max(near + far, Self.epsilon)
        return min(max(f, Self.edgeMargin), n - Self.edgeMargin)
    }

    // Where a tie at `s` sits: `s` of the way along the visible part of
    // each strand's straight run (out of one pane, into the other), on
    // average. Fixed there, like a mounted reel; it moves when you slide
    // it or its panes move.
    private func anchor(_ keys: [CableKey], at s: Double) -> Vec {
        let at = keys.compactMap { k -> Vec? in
            guard let c = cables[k], let e = edges[k] else { return nil }
            return Self.run(c.a.point, c.b.point, e, s)
        }
        return Self.mean(at)
    }

    // `s` of the way along the visible part of the straight run a -> b.
    private static func run(_ a: Vec, _ b: Vec, _ e: Edge, _ s: Double) -> Vec {
        let from = leave(a, b, e.parent)
        let to = max(from, 1 - leave(b, a, e.child))
        return a + (b - a) * (from + (to - from) * s)
    }

    // How far along p -> q (0...1) the line leaves r, p inside it.
    private static func leave(_ p: Vec, _ q: Vec, _ r: Rect) -> Double {
        let d = q - p
        var t = 1.0

        if d.x > epsilon { t = min(t, (r.x + r.w - p.x) / d.x) }
        if d.x < -epsilon { t = min(t, (r.x - p.x) / d.x) }
        if d.y > epsilon { t = min(t, (r.y + r.h - p.y) / d.y) }
        if d.y < -epsilon { t = min(t, (r.y - p.y) / d.y) }
        return max(t, 0)
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

    // The way a cable travels, a -> b, by how it leaves and enters its panes.
    // Ports on the same side of a pane share it however far the other ends
    // are spread, so a hub's five children do not read as five directions.
    private static func travel(_ c: Cable) -> Vec {
        let out = unit(c.a.normal - c.b.normal)
        return out.length > 0 ? out : unit(c.b.point - c.a.point)
    }

    // `v` scaled to length 1. The bundle's flow adds these up, so one strand
    // that runs far (a steep climb) does not tilt it away from the rest.
    private static func unit(_ v: Vec) -> Vec {
        v.length > 1e-6 ? v * (1 / v.length) : Vec(0, 0)
    }

    // The strands the tie can hold at `s`: those that pass it heading the
    // way the bundle flows. One that would have to double back through the
    // tie (a loop) is not held. The bundle's direction is the one the most
    // strands agree on.
    private func holders(_ t: CableTie, at s: Double? = nil) -> [CableTie.Member] {
        let live = t.members.filter { cables[$0.key] != nil }
        guard live.count >= 2 else { return live }

        let ends = live.map { (a: cables[$0.key]!.a.point, b: cables[$0.key]!.b.point) }
        let runs = live.map { Self.travel(cables[$0.key]!) }
        let mid = live.map { Self.at(cables[$0.key]!.pts, place(t, $0, at: s)) }
        var best = [Int]()

        for lead in live.indices {
            var flow = Vec(0, 0)
            var way = [Double]()
            for run in runs {
                way.append(run.dot(runs[lead]) < 0 ? -1 : 1)
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
        var f: [CableKey: Double] = [:]       // bead index it grips on each rope
        var s: Double
        var center = Vec(0, 0)                // where it sits: see anchor
        var flow = Vec(1, 0)                 // unit, port a -> port b
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

    // Work out every tie: its center (its anchor, over the strands it
    // holds), the direction the bundle flows (from the spots just before the
    // strands to just after: the neighboring tie, or the port), and each
    // strand's slot across it. Also keeps the pills' own numbers current.
    private func layout() -> Layout {
        var out = Layout()

        for t in ties {
            let live = holders(t)
            guard live.count >= 2 else { continue }

            var spot = Spot(keys: live.map(\.key), s: t.s)
            for m in live { spot.f[m.key] = place(t, m) }
            spot.center = anchor(spot.keys, at: t.s)
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

        spot.center = anchor(spot.keys, at: spot.s)
    }

    private func flow(_ spot: inout Spot, _ id: Int, _ out: Layout) {
        var runs = [CableKey: Vec]()
        for key in spot.keys {
            let chain = out.chains[key]!
            let k = chain.firstIndex(of: id)!
            let c = cables[key]!
            let before = k > 0 ? out.spots[chain[k - 1]]!.center : c.a.point
            let after = k + 1 < chain.count ? out.spots[chain[k + 1]]!.center : c.b.point
            // Alone on its cable the tie sees the ports' own heading; spread
            // ends would tilt the flow toward the steepest strand.
            runs[key] = chain.count == 1 ? Self.travel(c) : after - before
            spot.before[key] = before
            spot.after[key] = after
        }

        // Strands running the opposite way are flipped so they don't cancel.
        let lead = Self.travel(cables[spot.keys[0]]!)
        var sum = Vec(0, 0)
        for key in spot.keys {
            let way = Self.travel(cables[key]!).dot(lead) < 0 ? -1.0 : 1.0
            spot.way[key] = way
            sum = sum + Self.unit(runs[key]!) * way
        }
        if sum.length > 1e-6 { spot.flow = sum * (1 / sum.length) }

        // Slots follow the strands' order across the bundle.
        let cross = spot.cross
        let across = spot.keys.map { ($0, (Self.at(cables[$0]!.pts, spot.f[$0]!) - spot.center).dot(cross)) }
        let order = across.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.order < $1.0.order }
        for (rank, item) in order.enumerated() {
            spot.slot[item.0] = (Double(rank) - Double(order.count - 1) / 2) * Self.strandGap
        }
    }

    // Every tie is a reel mount at its spot: each strand's grip point is
    // held there, in its own slot across the bundle.
    private func grip(_ lay: Layout) {
        for spot in lay.spots.values {
            for key in spot.keys {
                let want = spot.center + spot.cross * spot.slot[key]!
                Self.nudge(&cables[key]!, spot.f[key]!, by: want - Self.at(cables[key]!.pts, spot.f[key]!))
            }
        }
    }

    // Moves the rope's point at fractional bead `f` by `d`, split between
    // the beads either side by how near each is: the point lands exactly.
    private static func nudge(_ c: inout Cable, _ f: Double, by d: Vec) {
        let i = min(Int(f), points - 2)
        let t = f - Double(i)
        let (wa, wb) = (isHeld(i) ? 0 : 1 - t, isHeld(i + 1) ? 0 : t)
        let w = wa * wa + wb * wb
        guard w > epsilon else { return }

        c.pts[i] = c.pts[i] + d * (wa / w)
        c.pts[i + 1] = c.pts[i + 1] + d * (wb / w)
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
            return spread(keys, at: t.s, ends) > Self.fanOutSpread * 1.5
        }
        declined = declined.filter { wanted[$0] != nil }

        for id in wanted.keys.sorted() {
            let keys = wanted[id]!
            guard !declined.contains(id), !ties.contains(where: { $0.fanOut == id }),
                  let s = Self.fanOutS.first(where: { spread(keys, at: $0, ends) <= Self.fanOutSpread })
            else { continue }

            var t = CableTie(id: nextTie, members: keys.map { .init(key: $0, delta: 0.0) }, s: s)
            t.fanOut = id
            nextTie += 1
            ties.append(t)
        }
        refreshTies()
    }

    // Widest gap between the strands where a tie at `s` would grip them
    // (see anchor), not inside the pane they all start under.
    private func spread(_ keys: [CableKey], at s: Double,
                        _ ends: [CableKey: (a: CableEnd, b: CableEnd)]) -> Double {
        let at = keys.compactMap { k -> Vec? in
            guard let x = ends[k], let e = edges[k] else { return nil }
            return Self.run(x.a.point, x.b.point, e, s)
        }
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
        guard found.count >= 2 else { return nil }

        // First guess where the stroke crossed: it picks which side of
        // its neighbors the tie lands on.
        let hit = Self.mean(found.map(\.point))
        var tie = CableTie(id: nextTie, members: found.map { .init(key: $0.key, delta: 0) }, s: 0)
        tie.s = project(tie, hit)
        tie.s = nearest(tie, to: hit, keep: 2) ?? tie.s
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

        // Saved by older builds: each strand gripped `delta` beads off `s`.
        // The tie sat at their average; fold it into `s`, once.
        let shift = live.map(\.delta).reduce(0, +) / Double(live.count) / Double(Self.points - 1)
        var tie = CableTie(id: nextTie, members: live.map { .init(key: $0.key, delta: 0) }, s: s + shift)
        guard let at = clear(tie, at: tie.s) else { return nil }

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
        guard let i = ties.firstIndex(where: { $0.id == id }),
              let s = nearest(ties[i], to: p, keep: max(2, ties[i].holds)) else { return }

        ties[i].s = s
        wake()
        refreshTies()
    }

    // The spot whose bundle center is nearest `p`, still holding `keep`
    // strands: a tie follows the mouse, however far apart its strands are.
    private func nearest(_ t: CableTie, to p: Vec, keep: Int) -> Double? {
        var best: (s: Double, d: Double)?
        let length = Double(Self.points - 1)

        for f in stride(from: 0.0, through: length, by: Self.scanStep) {
            guard let s = clear(t, at: f / length),
                  holders(t, at: s).count >= keep,
                  let c = center(t, at: s) else { continue }

            let d = (c - p).length
            if d < (best?.d ?? .infinity) { best = (s, d) }
        }
        return best?.s
    }

    // Where the tie would sit at `s`.
    private func center(_ t: CableTie, at s: Double) -> Vec? {
        let keys = t.members.map(\.key).filter { cables[$0] != nil }
        return keys.isEmpty ? nil : anchor(keys, at: s)
    }

    // The `s` (0...1) whose spot comes nearest `p`, ignoring neighbors.
    private func project(_ t: CableTie, _ p: Vec) -> Double {
        guard let start = center(t, at: 0), let end = center(t, at: 1) else { return t.s }

        let d = end - start
        return min(max((p - start).dot(d) / max(d.dot(d), Self.epsilon), 0), 1)
    }

    // `s` held off the cable ends, and tieGap clear of the closest ties
    // either side on each shared strand. Measured along that strand in
    // points, so the gap is the one you see, whatever the tie sets.
    //
    //   port ──── o ──gap──▶ t ──gap──▶ o' ──── port
    private func clear(_ t: CableTie, at s: Double) -> Double? {
        let keys = Set(t.members.map(\.key))
        var lo = Double(Self.tieEnds) / Double(Self.points - 1)
        var hi = 1 - lo
        guard let start = center(t, at: 0), let end = center(t, at: 1) else { return min(max(s, lo), hi) }

        for o in ties where o.id != t.id {
            guard let spot = center(o, at: o.s) else { continue }

            for key in o.members.map(\.key) where keys.contains(key) {
                guard let c = cables[key] else { continue }

                // Along the strand: t sits at p0 + slope * s, o at `other`.
                let dir = Self.unit(c.b.point - c.a.point)
                let (p0, slope, other) = (start.dot(dir), (end - start).dot(dir), spot.dot(dir))
                guard slope > Self.epsilon else { continue }

                if other <= p0 + slope * t.s {
                    lo = max(lo, (other + Self.tieGap - p0) / slope)
                } else {
                    hi = min(hi, (other - Self.tieGap - p0) / slope)
                }
            }
        }
        guard lo <= hi else { return nil }
        return min(max(s, lo), hi)
    }

    private static func length(_ pts: [Vec]) -> Double {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
    }
}
