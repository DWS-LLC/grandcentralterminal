// The canvas fill (background color, or the shader inside it) with a
// soft top edge: it dissolves to clear so the desktop shows through and
// meets the translucent menubar, instead of ending in a hard line.
//
//   ░░░░░░░░░░░░  menubar (blurs the desktop)
//   ░░░░░░░░░░░░  fill alpha 0   ─┐
//   ▒▒▒▒▒▒▒▒▒▒▒▒                  ├ fadeHeight
//   ▓▓▓▓▓▓▓▓▓▓▓▓                 ─┘
//   ████████████  fill alpha 1
//
// Needs a clear, non-opaque window: the fill paints the color itself,
// since the window's own background can't be masked. Panes live above
// it and stay unfaded.

import AppKit

final class FadedFillView: NSView {
    // A linear ramp shows a visible band where it starts; a curve
    // sampled at a few stops doesn't. The exponential one is steep, so
    // it gets more stops.
    private static let stops = 16
    private static let expRate: CGFloat = 4

    private let mask = CAGradientLayer()

    /// Points of fade from the top edge. 0 = solid, no mask.
    var fadeHeight: CGFloat = 0 {
        didSet {
            guard fadeHeight != oldValue else { return }
            needsLayout = true
        }
    }

    /// Exponential falloff toward the top edge; false = smoothstep.
    var exponential = true {
        didSet { needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        mask.startPoint = CGPoint(x: 0.5, y: 1)
        mask.endPoint = CGPoint(x: 0.5, y: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Solid fill color; nil paints nothing (a shader or the window does).
    func setColor(_ color: NSColor?) {
        layer?.backgroundColor = color?.cgColor
    }

    // t = 0 at the menubar edge, 1 at the end of the fade. Exponential:
    // alpha decays fast right at the menubar, then levels off to solid.
    private func ease(_ t: CGFloat) -> CGFloat {
        guard exponential else { return t * t * (3 - 2 * t) }
        return 1 - (exp(Self.expRate * (1 - t)) - 1) / (exp(Self.expRate) - 1)
    }

    override func layout() {
        super.layout()
        guard fadeHeight > 0, bounds.height > 0 else {
            layer?.mask = nil
            return
        }

        // Top `frac` of the height ramps 0 -> 1, the rest stays opaque.
        let frac = min(fadeHeight / bounds.height, 1)
        let ts = (0...Self.stops).map { CGFloat($0) / CGFloat(Self.stops) }
        let ramp = ts.map { t in
            (loc: Double(t * frac), alpha: ease(t))
        }
        let all = ramp + [(loc: 1.0, alpha: CGFloat(1))]
        mask.locations = all.map { NSNumber(value: $0.loc) }
        mask.colors = all.map { NSColor.black.withAlphaComponent($0.alpha).cgColor }
        mask.frame = bounds
        layer?.mask = mask
    }
}
