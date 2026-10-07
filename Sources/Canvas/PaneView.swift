// Visual chrome of one pane: titlebar, border, surface host.
// Frames are in WORLD coordinates (the world layer is camera-transformed).

import AppKit
import Common

final class PaneView: NSView {
    static let titleBarHeight: CGFloat = 22

    let id: PaneID
    private(set) var meta: PaneMeta
    private(set) var host: SurfaceHost?

    let surfaceHostView = NSView(frame: .zero)
    private let titlebar = NSView(frame: .zero)
    private let titleLabel = CATextLayer()

    var isFocused = false { didSet { applyChrome() } }

    init(meta: PaneMeta) {
        self.id = meta.id
        self.meta = meta
        super.init(frame: NSRect(x: meta.rect.x, y: meta.rect.y,
                                 width: meta.rect.w, height: meta.rect.h))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = false

        titlebar.wantsLayer = true
        titlebar.autoresizingMask = [.width]
        addSubview(titlebar)

        titleLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        titleLabel.fontSize = 12
        titleLabel.alignmentMode = .left
        titlebar.layer?.addSublayer(titleLabel)

        surfaceHostView.wantsLayer = true
        surfaceHostView.autoresizingMask = []
        addSubview(surfaceHostView)

        applyChrome()
        layoutChrome()
    }

    required init?(coder: NSCoder) { fatalError() }

    func install(host: SurfaceHost) {
        self.host = host
    }

    func update(meta: PaneMeta) {
        self.meta = meta
        layoutChrome()
        applyChrome()
    }

    func setRect(_ rect: NSRect, notifySurface: Bool) {
        frame = rect
        meta.rect = Rect(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
        layoutChrome()
        if notifySurface { syncSurfaceSize() }
    }

    // Resize the ghostty surface to match the content view's backing size.
    func syncSurfaceSize() {
        guard let host else { return }
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        host.setScale(scale)
        let px = UInt32(max(1, surfaceHostView.frame.width * scale))
        let py = UInt32(max(1, surfaceHostView.frame.height * scale))
        host.setSize(width: px, height: py)
    }

    override func layout() {
        super.layout()
        layoutChrome()
    }

    private func layoutChrome() {
        let w = bounds.width
        let h = bounds.height
        titlebar.frame = NSRect(x: 0, y: h - PaneView.titleBarHeight,
                                width: w, height: PaneView.titleBarHeight)
        surfaceHostView.frame = NSRect(x: 0, y: 0,
                                       width: w, height: h - PaneView.titleBarHeight)

        // Title text vertically centered, 8pt inset.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let textW = w - 16
        let textH: CGFloat = 15
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLabel.frame = CGRect(x: 8 * scale,
                                  y: (PaneView.titleBarHeight * scale - textH * scale) / 2,
                                  width: textW * scale,
                                  height: textH * scale)
        CATransaction.commit()
    }

    private func applyChrome() {
        let border = isFocused ? 0.28 : 0.19
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: border, alpha: 1).cgColor
        layer?.shadowOpacity = 0.55
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.shadowColor = NSColor.black.cgColor

        titlebar.layer?.backgroundColor =
            NSColor(white: isFocused ? 0.26 : 0.23, alpha: 1).cgColor

        titleLabel.string = titleText
        titleLabel.foregroundColor =
            NSColor(white: isFocused ? 0.88 : 0.66, alpha: 1).cgColor
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    }

    private var titleText: String {
        let host_ = meta.host
        let kind = meta.name ?? "Terminal"
        return "\(host_) – \(kind) – \(meta.cwd)"
    }

    // Hit zones for manual routing (world coords).
    enum ResizeZone {
        case n, s, e, w, ne, nw, se, sw
    }

    func resizeZone(at worldPoint: CGPoint, screenTolerance t: CGFloat) -> ResizeZone? {
        let r = frame
        let inside = worldPoint.x >= r.minX - t && worldPoint.x <= r.maxX + t
            && worldPoint.y >= r.minY - t && worldPoint.y <= r.maxY + t
        guard inside,
              worldPoint.x <= r.minX + t || worldPoint.x >= r.maxX - t
                  || worldPoint.y <= r.minY + t || worldPoint.y >= r.maxY - t
        else { return nil }

        let nearW = abs(worldPoint.x - r.minX) <= t
        let nearE = abs(worldPoint.x - r.maxX) <= t
        let nearS = abs(worldPoint.y - r.minY) <= t
        let nearN = abs(worldPoint.y - r.maxY) <= t
        switch (nearW, nearE, nearS, nearN) {
        case (true, false, false, true): return .nw
        case (false, true, false, true): return .ne
        case (true, false, true, false): return .sw
        case (false, true, true, false): return .se
        case (true, false, false, false): return .w
        case (false, true, false, false): return .e
        case (false, false, true, false): return .s
        case (false, false, false, true): return .n
        default: return nil
        }
    }

    func isInTitlebar(_ worldPoint: CGPoint) -> Bool {
        worldPoint.y >= frame.maxY - PaneView.titleBarHeight
            && frame.contains(worldPoint)
    }

    func containsWorld(_ worldPoint: CGPoint) -> Bool {
        frame.contains(worldPoint)
    }
}
