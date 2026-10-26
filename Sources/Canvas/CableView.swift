// Draws the cable sim: one stroked path per cable, a dot at each port, a
// grey pill per tie, and the stroke you are dragging out to make a tie. A plain world-space view under the panes
// (the world transform scales it with the camera), so it never takes a click.
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
    private static let strokeColor = NSColor(calibratedRed: 0.55, green: 0.7, blue: 1, alpha: 0.95)
    private static let calmAlpha: Float = 0.55
    private static let tickRate: TimeInterval = 1.0 / 60

    private final class Line {
        let stroke = CAShapeLayer()
        let ports = CAShapeLayer()
    }

    let sim = CableSim()
    // The tie under the mouse, between press and release.
    var grabbed: Int?
    // The tie-making stroke, world points, while the mouse is down.
    var stroke: (from: Vec, to: Vec)?

    private var lines = [CableKey: Line]()
    private var tieLayers = [Int: CAShapeLayer]()
    private let strokeLayer = CAShapeLayer()
    private var timer: Timer?

    // Frame is a formality: sublayers draw in world coordinates, unclipped.
    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        wantsLayer = true
        layer?.masksToBounds = false

        strokeLayer.fillColor = nil
        strokeLayer.strokeColor = Self.strokeColor.cgColor
        strokeLayer.lineCap = .round
        strokeLayer.zPosition = 2
        layer?.addSublayer(strokeLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func start(_ tick: @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickRate, repeats: true) { _ in tick() }
    }

    // `colors` has one entry per cable; `bright` are the ones touching the
    // focused pane (the rest sit back). `zoom` is the camera scale.
    func render(colors: [CableKey: NSColor], bright: Set<CableKey>, zoom: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let width = max(Self.lineWidth, Self.minScreenWidth / max(zoom, 0.001))
        for key in lines.keys where sim.cables[key] == nil {
            remove(lines.removeValue(forKey: key))
        }

        for (key, cable) in sim.cables {
            let line = lines[key] ?? make(key)
            let color = (colors[key] ?? .systemBlue).cgColor
            let opacity = bright.isEmpty || bright.contains(key) ? 1 : Self.calmAlpha

            line.stroke.path = Self.path(cable.pts)
            line.stroke.strokeColor = color
            line.stroke.lineWidth = width
            line.stroke.opacity = opacity

            let radius = Self.portRadius * max(1, width / Self.lineWidth)
            let dots = CGMutablePath()
            for end in [cable.a, cable.b] {
                dots.addEllipse(in: CGRect(x: end.point.x - radius, y: end.point.y - radius,
                                           width: radius * 2, height: radius * 2))
            }
            line.ports.path = dots
            line.ports.fillColor = color
            line.ports.opacity = opacity
        }

        renderTies(width: width)
        renderStroke(width: width)
    }

    private func make(_ key: CableKey) -> Line {
        let line = Line()
        line.stroke.fillColor = nil
        line.stroke.lineCap = .round
        line.stroke.lineJoin = .round
        layer?.addSublayer(line.stroke)
        layer?.addSublayer(line.ports)
        lines[key] = line
        return line
    }

    private func remove(_ line: Line?) {
        line?.stroke.removeFromSuperlayer()
        line?.ports.removeFromSuperlayer()
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

    private func renderStroke(width: CGFloat) {
        guard let s = stroke else {
            strokeLayer.path = nil
            return
        }

        let p = CGMutablePath()
        p.move(to: CGPoint(x: s.from.x, y: s.from.y))
        p.addLine(to: CGPoint(x: s.to.x, y: s.to.y))
        strokeLayer.path = p
        strokeLayer.lineWidth = width * 0.8
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
}
