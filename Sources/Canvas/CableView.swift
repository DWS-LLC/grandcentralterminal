// Draws the cable sim: one stroked path per cable, a dot at each port, a
// grey pill per tie. A plain world-space view under the panes (the world
// transform scales it with the camera), so it never takes a click.
//
//   CableSim (Common) ──► CableView ──► CAShapeLayer per cable / tie

import AppKit
import Common

final class CableView: NSView {
    private static let lineWidth: CGFloat = 2.2
    // Never thinner than this on screen, however far out the camera is.
    private static let minScreenWidth: CGFloat = 1.5
    private static let portRadius: CGFloat = 3.4
    private static let tieThickness: CGFloat = 5
    private static let tieColor = NSColor(white: 0.78, alpha: 1)
    private static let tieEdge = NSColor(white: 0.1, alpha: 0.55)
    private static let calmAlpha: CGFloat = 0.55
    private static let tickRate: TimeInterval = 1.0 / 60

    let sim = CableSim()
    // The tie under the mouse, between press and release.
    var grabbed: Int?

    private var cableLayers = [CableKey: CAShapeLayer]()
    private var portLayers = [CableKey: CAShapeLayer]()
    private var tieLayers = [Int: CAShapeLayer]()
    private var timer: Timer?

    // Frame is a formality: sublayers draw in world coordinates, unclipped.
    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func start(_ tick: @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickRate, repeats: true) { _ in tick() }
    }

    // `colors` decides which cables exist visually; `bright` are the ones
    // touching the focused pane (the rest sit back). `zoom` is the camera
    // scale.
    func render(colors: [CableKey: NSColor], bright: Set<CableKey>, zoom: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let width = max(Self.lineWidth, Self.minScreenWidth / max(zoom, 0.001))
        prune(&cableLayers, keep: Set(sim.cables.keys))
        prune(&portLayers, keep: Set(sim.cables.keys))

        for (key, cable) in sim.cables {
            let color = colors[key] ?? .systemBlue
            let alpha = bright.isEmpty || bright.contains(key) ? 1 : Self.calmAlpha

            let line = layerFor(key, in: &cableLayers)
            line.path = Self.path(cable.pts)
            line.strokeColor = color.withAlphaComponent(alpha).cgColor
            line.lineWidth = width

            let ports = layerFor(key, in: &portLayers)
            ports.path = Self.dots([cable.a.point, cable.b.point], radius: Self.portRadius * max(1, width / Self.lineWidth))
            ports.fillColor = color.withAlphaComponent(alpha).cgColor
        }

        renderTies(width: width)
    }

    private func renderTies(width: CGFloat) {
        let live = Set(sim.ties.map(\.id))
        for id in tieLayers.keys where !live.contains(id) {
            tieLayers.removeValue(forKey: id)?.removeFromSuperlayer()
        }

        let scale = max(1, width / Self.lineWidth)
        for tie in sim.ties {
            let pill = tieLayers[tie.id] ?? makeTieLayer(tie.id)
            let w = CGFloat(tie.width) * scale
            let h = Self.tieThickness * scale

            pill.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            pill.path = CGPath(roundedRect: pill.bounds, cornerWidth: h / 2, cornerHeight: h / 2,
                               transform: nil)
            pill.position = CGPoint(x: tie.center.x, y: tie.center.y)
            pill.transform = CATransform3DMakeRotation(CGFloat(tie.angle), 0, 0, 1)
            pill.lineWidth = grabbed == tie.id ? 1.6 : 1
        }
    }

    private func makeTieLayer(_ id: Int) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.fillColor = Self.tieColor.cgColor
        l.strokeColor = Self.tieEdge.cgColor
        l.zPosition = 1
        layer?.addSublayer(l)
        tieLayers[id] = l
        return l
    }

    private func layerFor(_ key: CableKey, in table: inout [CableKey: CAShapeLayer]) -> CAShapeLayer {
        if let l = table[key] { return l }

        let l = CAShapeLayer()
        l.fillColor = nil
        l.lineCap = .round
        l.lineJoin = .round
        layer?.addSublayer(l)
        table[key] = l
        return l
    }

    private func prune(_ table: inout [CableKey: CAShapeLayer], keep: Set<CableKey>) {
        for key in table.keys where !keep.contains(key) {
            table.removeValue(forKey: key)?.removeFromSuperlayer()
        }
    }

    // Smooth through the points: quad curves between midpoints.
    private static func path(_ pts: [Vec]) -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first, let last = pts.last else { return p }

        p.move(to: CGPoint(x: first.x, y: first.y))
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            p.addQuadCurve(to: mid, control: CGPoint(x: pts[i].x, y: pts[i].y))
        }
        p.addLine(to: CGPoint(x: last.x, y: last.y))
        return p
    }

    private static func dots(_ at: [Vec], radius: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for v in at {
            p.addEllipse(in: CGRect(x: v.x - radius, y: v.y - radius, width: radius * 2, height: radius * 2))
        }
        return p
    }
}
