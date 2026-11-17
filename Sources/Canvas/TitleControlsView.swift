// What sits left of a pane's title: the window controls (macOS's traffic
// lights) and the icon of the program running in it.
//
//   titlebar layer
//   ├── TitleControls.layer      ●  ●  ●  ⋯     close, float, zoom, menu
//   │     ├── dot   x3           the colored circles
//   │     └── glyph x4           × ↑ ⤢ ⋯, drawn only while the cluster is hovered
//   └── TitleIcon.layer          [app icon], or >_ when the program has none
//
// Layers, not views: the canvas routes every click itself, and shape layers
// stay sharp under the camera's zoom. Geometry comes from Common's
// TitleControlsLayout; this file only paints it.

import AppKit
import Common

final class TitleControls {
    enum Hover: Equatable {
        case away
        case cluster
        case control(TitleControl)
    }

    // Past this far out the controls stand down, so a click can't be luck.
    enum Reach {
        case near
        case far
    }

    // What the dots need to know about their pane.
    struct Look: Equatable {
        var lit = false       // focused, selected or zoomed: dots wear their color
        var floating = false  // the float dot offers to put it back
        var zoomed = false    // the zoom dot offers to shrink it
        var text = NSColor.gray
    }

    // A dot is a few pixels below this camera scale.
    static let minScale: CGFloat = 0.6

    private enum Glow { case idle, lit }
    private enum Glyphs { case hidden, shown }
    private enum Heading { case up, down }

    // macOS's own: #FF5F57, #FEBC2E, #28C840.
    private static let colors: [TitleControl: NSColor] = [
        .close: NSColor(srgbRed: 1.000, green: 0.373, blue: 0.341, alpha: 1),
        .float: NSColor(srgbRed: 1.000, green: 0.737, blue: 0.180, alpha: 1),
        .zoom: NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1),
    ]
    private static let idleAlpha: CGFloat = 0.3
    private static let rimAlpha: CGFloat = 0.15
    private static let rimWidth: CGFloat = 0.5
    private static let pressDarken: CGFloat = 0.25
    private static let glyphAlpha: CGFloat = 0.6
    private static let menuAlpha: CGFloat = 0.7
    private static let farOpacity: Float = 0.35

    // Glyph geometry, in fractions of the dot's edge:
    //
    //   far  ┤          ↗      strokes run edge..far,
    //        │        ╱        an arrowhead's arms are `arm` long,
    //   mid  ┤      ╱          inward heads stop `kiss` short of the middle.
    //        │    ╱
    //   edge ┤  ↙
    private static let edge: CGFloat = 0.26
    private static let far: CGFloat = 1 - edge
    private static let mid: CGFloat = 0.5
    private static let arm: CGFloat = 0.22
    private static let kiss: CGFloat = 0.04
    private static let crossLo: CGFloat = 0.3
    private static let crossHi: CGFloat = 0.7
    private static let strokeShare: CGFloat = 0.11
    private static let pipRadius: CGFloat = 0.075
    private static let pipSpread: CGFloat = 0.3

    let layer = CALayer()

    private var layout = TitleControlsLayout(barHeight: 0)
    private var dots = [TitleControl: CAShapeLayer]()
    private var glyphs = [TitleControl: CAShapeLayer]()

    var look = Look() { didSet { if look != oldValue { render() } } }
    var hover = Hover.away { didSet { if hover != oldValue { render() } } }
    var pressed: TitleControl? { didSet { if pressed != oldValue { render() } } }
    var reach = Reach.near {
        didSet {
            guard reach != oldValue else {
                return
            }
            layer.opacity = reach == .near ? 1 : Self.farOpacity
        }
    }

    init() {
        for control in TitleControl.allCases {
            if Self.colors[control] != nil {
                let dot = CAShapeLayer()
                dot.strokeColor = NSColor.black.withAlphaComponent(Self.rimAlpha).cgColor
                dot.lineWidth = Self.rimWidth
                dots[control] = dot
                layer.addSublayer(dot)
            }

            // CAShapeLayer fills black unless told not to.
            let glyph = CAShapeLayer()
            glyph.fillColor = nil
            glyph.strokeColor = nil
            glyph.lineCap = .round
            glyph.lineJoin = .round
            glyphs[control] = glyph
            layer.addSublayer(glyph)
        }
    }

    /// Room the controls take from the titlebar's left edge.
    var width: CGFloat { layout.width }

    func fit(barHeight: CGFloat) {
        guard layout.barHeight != barHeight else {
            return
        }

        layout = TitleControlsLayout(barHeight: barHeight)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(x: 0, y: 0, width: layout.width, height: barHeight)
        for control in TitleControl.allCases {
            let frame = layout.frame(of: control)
            let circle = CGPath(ellipseIn: CGRect(origin: .zero, size: frame.size), transform: nil)
            dots[control]?.frame = frame
            dots[control]?.path = circle
            glyphs[control]?.frame = frame
        }
        CATransaction.commit()

        render()
    }

    /// Where `point` (titlebar coordinates) lands.
    func hover(at point: CGPoint) -> Hover {
        if let control = layout.hit(point) {
            return .control(control)
        }
        return layout.cluster.contains(point) ? .cluster : .away
    }

    private func render() {
        let glow = look.lit || hover != .away ? Glow.lit : Glow.idle
        let glyphs = hover == .away ? Glyphs.hidden : Glyphs.shown

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for control in TitleControl.allCases {
            paintDot(control, glow)
            paintGlyph(control, glyphs)
        }
        CATransaction.commit()
    }

    private func paintDot(_ control: TitleControl, _ glow: Glow) {
        guard let dot = dots[control], let color = Self.colors[control] else {
            return
        }

        var fill = glow == .lit ? color : look.text.withAlphaComponent(Self.idleAlpha)
        if pressed == control {
            fill = fill.blended(withFraction: Self.pressDarken, of: .black) ?? fill
        }
        dot.fillColor = fill.cgColor
    }

    private func paintGlyph(_ control: TitleControl, _ shown: Glyphs) {
        guard let glyph = glyphs[control] else {
            return
        }

        glyph.isHidden = shown == .hidden
        guard shown == .shown else {
            return
        }

        let edge = layout.frame(of: control).width
        glyph.path = glyphPath(control, edge: edge)

        // The menu is three filled pips in the title's own color; the dots'
        // glyphs are dark strokes, like macOS's.
        guard control == .menu else {
            glyph.strokeColor = NSColor.black.withAlphaComponent(Self.glyphAlpha).cgColor
            glyph.lineWidth = Self.strokeShare * edge
            return
        }

        let strong = hover == .control(.menu) || pressed == .menu
        glyph.fillColor = look.text.withAlphaComponent(strong ? 1 : Self.menuAlpha).cgColor
    }

    // MARK: Glyphs

    private func glyphPath(_ control: TitleControl, edge d: CGFloat) -> CGPath {
        let path = CGMutablePath()

        func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
            path.move(to: CGPoint(x: x0 * d, y: y0 * d))
            path.addLine(to: CGPoint(x: x1 * d, y: y1 * d))
        }

        switch control {
        case .close:
            cross(line)
        case .float:
            arrow(line, look.floating ? .down : .up)
        case .zoom:
            look.zoomed ? shrink(line) : grow(line)
        case .menu:
            pips(path, d)
        }
        return path
    }

    private typealias Line = (CGFloat, CGFloat, CGFloat, CGFloat) -> Void

    // ×
    private func cross(_ line: Line) {
        line(Self.crossLo, Self.crossLo, Self.crossHi, Self.crossHi)
        line(Self.crossLo, Self.crossHi, Self.crossHi, Self.crossLo)
    }

    // ↑ lifts the pane above the others, ↓ puts it back.
    private func arrow(_ line: Line, _ heading: Heading) {
        let tip = heading == .up ? Self.far : Self.edge
        let tail = heading == .up ? Self.edge : Self.far
        let back = heading == .up ? -Self.arm : Self.arm

        line(Self.mid, tail, Self.mid, tip)
        line(Self.mid, tip, Self.mid - Self.arm, tip + back)
        line(Self.mid, tip, Self.mid + Self.arm, tip + back)
    }

    // ⤢ both heads point out to the corners.
    private func grow(_ line: Line) {
        let far = Self.far, edge = Self.edge, arm = Self.arm

        line(edge, edge, far, far)
        line(far, far, far - arm, far)
        line(far, far, far, far - arm)
        line(edge, edge, edge + arm, edge)
        line(edge, edge, edge, edge + arm)
    }

    // ⤡ both heads point in to the middle.
    private func shrink(_ line: Line) {
        let hi = Self.mid + Self.kiss, lo = Self.mid - Self.kiss
        let far = Self.far, edge = Self.edge, arm = Self.arm

        line(far, far, hi, hi)
        line(hi, hi, hi + arm, hi)
        line(hi, hi, hi, hi + arm)
        line(edge, edge, lo, lo)
        line(lo, lo, lo - arm, lo)
        line(lo, lo, lo, lo - arm)
    }

    // ⋯
    private func pips(_ path: CGMutablePath, _ d: CGFloat) {
        let r = Self.pipRadius * d
        for step in [-1, 0, 1] {
            let x = (Self.mid + CGFloat(step) * Self.pipSpread) * d
            path.addEllipse(in: CGRect(x: x - r, y: Self.mid * d - r, width: r * 2, height: r * 2))
        }
    }
}

// The program's icon, or >_ for a plain terminal.
final class TitleIcon {
    private static let text = ">_"
    // Icon edge as a multiple of the title font: 17pt beside 13pt text.
    private static let sizeOverFont: CGFloat = 1.3
    private static let fontOverEdge: CGFloat = 0.8

    let layer = CALayer()
    private let picture = CALayer()
    private let glyph = CATextLayer()
    private var edge: CGFloat = 0

    init() {
        picture.minificationFilter = .trilinear
        picture.magnificationFilter = .linear
        picture.isHidden = true

        glyph.string = Self.text
        glyph.alignmentMode = .center
        glyph.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        layer.addSublayer(picture)
        layer.addSublayer(glyph)
    }

    /// Sizes the icon for `font` and returns its edge.
    func fit(font: NSFont) -> CGFloat {
        let edge = (font.pointSize * Self.sizeOverFont).rounded()
        guard edge != self.edge else {
            return edge
        }

        self.edge = edge
        let mono = NSFont.monospacedSystemFont(ofSize: edge * Self.fontOverEdge, weight: .bold)
        let lineHeight = ceil(mono.ascender - mono.descender)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = CGRect(x: 0, y: 0, width: edge, height: edge)
        glyph.font = mono
        glyph.fontSize = mono.pointSize
        glyph.frame = CGRect(x: 0, y: (edge - lineHeight) / 2, width: edge, height: lineHeight)
        CATransaction.commit()
        return edge
    }

    func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        picture.isHidden = image == nil
        glyph.isHidden = image != nil
        CATransaction.commit()
    }

    func tint(_ color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.foregroundColor = color.cgColor
        CATransaction.commit()
    }

    // The same re-rasterize-at-rest as the title text.
    func syncZoom(camera: CGFloat, window: NSWindow?) {
        PaneView.setTextScale(glyph, camera: camera, window: window)
    }
}
