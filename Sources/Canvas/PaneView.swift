// Visual chrome of one pane: titlebar, border, surface host.
// Frames are in WORLD coordinates (the world layer is camera-transformed).

import AppKit
import Common

final class PaneView: NSView {
    private static let baseTitleBarHeight: CGFloat = 22
    private static let baseTitleFontSize: CGFloat = 12

    // Scales with the title font (22pt at 12pt, 44pt at 24pt); never
    // shrinks below the base so small fonts keep the old bar.
    static var titleBarHeight: CGFloat {
        let size = GCTTheme.current.titleFont.pointSize
        return max(baseTitleBarHeight, ceil(size * baseTitleBarHeight / baseTitleFontSize))
    }

    let id: PaneID
    private(set) var meta: PaneMeta
    private(set) var host: SurfaceHost?

    let surfaceHostView = NSView(frame: .zero)
    private let titlebar = NSView(frame: .zero)
    private let titleLabel = CATextLayer()
    private let statusLabel = CATextLayer()
    // Veil over the whole pane: dims quiet unfocused panes (see CanvasDim).
    private let dimLayer = CALayer()
    // OSC 7501 program status, right-aligned in the titlebar (nil = none).
    var programStatus: ProgramStatusStore.Summary? { didSet { applyChrome() } }

    // Program title (OSC 0/2). Canvas-side only: daemon metas never carry
    // it, so it lives here instead of in `meta`. Feeds auto names.
    var reportedTitle: String?
    // Name for a pane with no custom name (AutoName), set by the canvas.
    var autoName: String? { didSet { if autoName != oldValue { applyChrome() } } }
    // Something happened here while you were elsewhere (notification, bell);
    // cleared once you look or type. Marks the title and keeps it undimmed.
    var hasNotice = false { didSet { if hasNotice != oldValue { applyChrome() } } }
    var displayName: String { meta.name ?? autoName ?? "Terminal" }

    var isFocused = false { didSet { applyChrome() } }
    // Multi-select: staged by right-drag/shift+click, acts as a unit for
    // move/close/group. Rendered with the accent color so it reads apart
    // from single-pane focus.
    var isSelected = false { didSet { if isSelected != oldValue { applyChrome() } } }
    // Focus zoom: set by CanvasView while this pane fills the viewport.
    // Renders the ⤢ marker + zoom chrome via applyChrome.
    var isZoomed = false { didSet { if isZoomed != oldValue { applyChrome() } } }

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
        // Square titlebar corners would poke past the pane's rounded
        // corners; round just the top pair to match.
        titlebar.layer?.cornerRadius = 6
        titlebar.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        titlebar.layer?.masksToBounds = true
        addSubview(titlebar)

        titleLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        titleLabel.alignmentMode = .left
        titleLabel.truncationMode = .end
        titlebar.layer?.addSublayer(titleLabel)
        statusLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        statusLabel.alignmentMode = .right
        statusLabel.truncationMode = .end
        titlebar.layer?.addSublayer(statusLabel)

        surfaceHostView.wantsLayer = true
        surfaceHostView.autoresizingMask = []
        addSubview(surfaceHostView)

        dimLayer.cornerRadius = 6
        dimLayer.opacity = 0
        dimLayer.zPosition = 1
        layer?.addSublayer(dimLayer)

        applyChrome()
        layoutChrome()
    }

    required init?(coder: NSCoder) { fatalError() }

    func install(host: SurfaceHost) {
        self.host = host
    }

    // Daemon rects arrive pre-resolved (the daemon arbitrates layout):
    // apply as-is. The != guard breaks the echo loop (our own setRect ->
    // movePane -> broadcast -> update). Must run on main (frame mutation).
    // INVARIANT: meta.rect == frame, except while zoomed (setZoomFrame).
    func update(meta: PaneMeta) {
        let r = NSRect(x: meta.rect.x, y: meta.rect.y,
                       width: meta.rect.w, height: meta.rect.h)
        // A zoomed pane's frame is the local fullscreen; meta.rect keeps
        // the real one until unzoom.
        if r != frame, !isZoomed {
            assert(Thread.isMainThread, "update(meta:) off main")
            setRect(r, notifySurface: true)
        }
        self.meta = meta
        layoutChrome()
        applyChrome()
    }
    // Daemon truth (name/color/group) without touching the frame: the
    // zoomed pane's fullscreen rect is local-only until unzoom.
    func syncMetaOnly(_ meta: PaneMeta) {
        self.meta.host = meta.host
        self.meta.name = meta.name
        self.meta.title = meta.title
        self.meta.cwd = meta.cwd
        self.meta.floating = meta.floating
        applyChrome()
    }

    // Local-only frame (focus zoom): meta.rect stays the real rect, so
    // placement and daemon moves never see the fullscreen one.
    func setZoomFrame(_ rect: NSRect) {
        frame = rect
        layoutChrome()
        syncSurfaceSize()
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
        let backing = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        // A vector-zoomed surface keeps its camera-matched scale.
        let scale = host.scaleOverride ?? backing
        host.setScale(scale)
        let px = UInt32(max(1, surfaceHostView.frame.width * scale))
        let py = UInt32(max(1, surfaceHostView.frame.height * scale))
        host.setSize(width: px, height: py)
    }

    // Vector zoom: lower bound where tiny cells stop being worth it, and
    // caps so a zoomed-in pane never allocates a giant drawable.
    private static let minRenderZoom: CGFloat = 0.5
    private static let maxDrawableSide: CGFloat = 8192
    private static let maxDrawablePixels: CGFloat = 24_000_000
    private static let zoomTolerance: CGFloat = 0.015

    // Re-render the terminal sharp at the camera's scale. Cheap no-op when
    // already within tolerance. Returns false if the grid refused to hold.
    @discardableResult
    func syncRenderZoom(camera: CGFloat) -> Bool {
        guard let host else { return true }
        let points = surfaceHostView.bounds.size
        guard points.width > 0, points.height > 0 else { return true }

        let backing = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        let sideCap = Self.maxDrawableSide / (max(points.width, points.height) * backing)
        let areaCap = (Self.maxDrawablePixels / (points.width * points.height)).squareRoot() / backing
        let zoom = min(max(camera, Self.minRenderZoom), max(1, min(sideCap, areaCap)))
        guard abs(zoom / CGFloat(host.zoom) - 1) > Self.zoomTolerance else { return true }

        return host.renderZoom(Double(zoom), base: backing, points: points) == .applied
    }

    // Vector titles: CATextLayer rasterizes at contentsScale, and the
    // camera only scales that bitmap. Re-rasterize at backing * camera
    // once it rests (2x backing at 4x zoom = 8x contents), so zoomed-in
    // titles stay crisp. Never below backing; capped in pixels.
    private static let maxTextPixels: CGFloat = 4_000_000

    func syncTitleZoom(camera: CGFloat) {
        for label in [titleLabel, statusLabel] {
            Self.setTextScale(label, camera: camera, window: window)
        }
    }

    static func setTextScale(_ label: CATextLayer, camera: CGFloat, window: NSWindow?) {
        let backing = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        let points = max(1, label.bounds.width * label.bounds.height)
        let cap = (maxTextPixels / points).squareRoot()
        let scale = max(backing, min(backing * camera, cap))
        guard label.contentsScale != scale else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.contentsScale = scale
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layoutChrome()
    }

    private func layoutChrome() {
        let w = bounds.width
        let h = bounds.height
        let bw = GCTTheme.current.borderWidth
        // Titlebar spans the full width (it hides the top border); the
        // terminal insets for the side/bottom border.
        titlebar.frame = NSRect(x: 0, y: h - PaneView.titleBarHeight,
                                width: w, height: PaneView.titleBarHeight)
        surfaceHostView.frame = NSRect(x: bw, y: bw,
                                       width: max(0, w - bw * 2),
                                       height: max(0, h - PaneView.titleBarHeight - bw))
        // Concentric rounding: square terminal corners would poke past
        // the pane's rounded border at wide border widths.
        let inner: CGFloat = max(0, 6 - bw)
        surfaceHostView.layer?.cornerRadius = inner
        surfaceHostView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        surfaceHostView.layer?.masksToBounds = inner > 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        CATransaction.commit()

        // Title text vertically centered, 8pt inset. Sublayer frames are
        // in points, not pixels — no backing-scale multiplication.
        let textH = min(PaneView.titleBarHeight - 6, GCTTheme.current.titleFont.pointSize + 3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if programStatus != nil {
            // Status docks right (8pt margin, half the bar max); the
            // title takes the rest. Narrow panes squeeze the status
            // first, truncating its tail (the state glyph stays put).
            let statusW = min(w / 2, statusLabel.preferredFrameSize().width)
            statusLabel.frame = CGRect(x: w - 8 - statusW,
                                       y: (PaneView.titleBarHeight - textH) / 2,
                                       width: statusW, height: textH)
            titleLabel.frame = CGRect(x: 8, y: (PaneView.titleBarHeight - textH) / 2,
                                      width: max(0, w - 16 - statusW - 8), height: textH)
        } else {
            titleLabel.frame = CGRect(x: 8, y: (PaneView.titleBarHeight - textH) / 2,
                                      width: max(0, w - 16), height: textH)
            statusLabel.frame = .zero
        }
        CATransaction.commit()
    }

    // Fade the pane toward the canvas (0 = untouched). Animated by the
    // layer's implicit 0.25s opacity transition.
    func setDim(_ amount: Float) {
        guard amount != dimLayer.opacity else { return }
        dimLayer.backgroundColor = (GCTTheme.isDark() ? NSColor.black : NSColor.white).cgColor
        dimLayer.opacity = amount
    }

    // Colors + font come from GCTTheme; re-run on focus and theme changes.
    // Floating panes get a pin marker + heavier shadow so they read at a
    // glance; the border fill stays the theme color.
    // Remote panes wear their host color: the titlebar text is tinted and
    // a 3pt host-color strip runs down the left edge (via the border
    // fill — local panes keep the theme chrome exactly).
    func applyChrome() {
        let t = GCTTheme.current
        layer?.borderWidth = 0
        layer?.borderColor = nil
        // Multi-select beats focus: selected panes wear accent chrome so a
        // 2+ selection reads apart from the single focused pane. A
        // focused-but-unselected pane keeps the normal focused look.
        // Zoomed panes wear it too (same weight as the float pin).
        let accent = isSelected || isZoomed
        let hostColor = HostStyle.color(for: meta.host)
        // Fill the pane behind the terminal with the titlebar color: the
        // inset terminal leaves the side/bottom border visible. Remote
        // panes tint the border fill with the host color so the whole
        // frame reads as foreign at any zoom.
        if accent {
            layer?.backgroundColor = t.accent.cgColor
        } else if let hc = hostColor {
            layer?.backgroundColor = hc.cgColor
        } else {
            layer?.backgroundColor = (isFocused ? t.borderFocused : t.borderUnfocused).cgColor
        }
        // Floating/zoomed reads at a glance: deeper shadow lifts it off
        // the canvas; plain titlebar otherwise.
        let lifted = meta.floating || isZoomed
        layer?.shadowOpacity = lifted ? min(1, t.shadowOpacity + 0.25) : t.shadowOpacity
        layer?.shadowRadius = lifted ? t.shadowRadius + 6 : t.shadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.shadowColor = t.shadowColor.cgColor
        titlebar.layer?.backgroundColor =
            (accent ? t.accent : isFocused ? t.titlebarBackgroundFocused : t.titlebarBackgroundUnfocused).cgColor
        titleLabel.string = titleText
        // Remote host tint on the title text (keeps titlebar grey, adds
        // the color where the eye lands). Local panes keep theme text.
        if !accent, let hc = hostColor {
            titleLabel.foregroundColor = hc.cgColor
        } else {
            titleLabel.foregroundColor =
                ((isFocused || isZoomed) ? t.titlebarTextFocused : t.titlebarTextUnfocused).cgColor
        }
        titleLabel.font = t.titleFont
        titleLabel.fontSize = t.titleFont.pointSize
        // Program status: same font, theme text color. blocked/error
        // borrow attention colors so they read without clicking in.
        statusLabel.string = programStatus?.text
        let scol: NSColor
        // Attention states win over accent/host tint; on the blue accent
        // titlebar red/orange vanish, so they get light variants.
        if programStatus?.state == .blocked {
            scol = accent ? .systemYellow : .systemOrange
        } else if programStatus?.state == .error {
            scol = accent ? .systemPink : .systemRed
        } else if accent {
            scol = .white
        } else if let hc = hostColor {
            scol = hc
        } else {
            scol = (isFocused || isZoomed) ? t.titlebarTextFocused : t.titlebarTextUnfocused
        }
        statusLabel.foregroundColor = scol.cgColor
        statusLabel.font = t.titleFont
        statusLabel.fontSize = t.titleFont.pointSize
        layoutChrome()
    }

    private var titleText: String {
        // Remote panes lead with [host] so the owner reads in the
        // switcher, screenshots, and anywhere the title goes. Local
        // panes keep the existing "host – name – cwd" shape ("local"
        // elided: it was always "local – Terminal – …" before).
        let kind = displayName
        let pin = meta.floating ? "⬆ " : ""
        let zoom = isZoomed ? "⤢ " : ""
        let notice = hasNotice ? "● " : ""
        let cwd = Self.tilde(meta.cwd, local: meta.host == "local" || meta.host.isEmpty)
        if meta.host == "local" || meta.host.isEmpty {
            return "\(notice)\(zoom)\(pin)\(kind) – \(cwd)"
        }
        return "\(notice)\(zoom)\(pin)[\(meta.host)] \(kind) – \(cwd)"
    }

    // The cwd tail is what truncation eats first; "~" buys it back.
    private static func tilde(_ path: String, local: Bool) -> String {
        let home = NSHomeDirectory()
        guard local, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

// Per-host window color: config [host.<name>] color wins, else a
// ghostty ANSI color picked by hashing the host name (stable across
// launches and machines; group palette when ghostty gave none).
// "local" returns nil (theme chrome, unchanged).
enum HostStyle {
    static func color(for host: String) -> NSColor? {
        guard host != "local", !host.isEmpty else { return nil }
        if let h = GCTConfig.current.remotes.first(where: { $0.name == host }),
           let c = h.color.spec(dark: GCTTheme.isDark()), let nc = NSColor(gctHex: c) {
            return nc
        }
        guard GCTConfig.current.remotes.contains(where: { $0.name == host }) else {
            // Unknown host (stale pane after config removal): grey it.
            return NSColor.systemGray
        }
        let ansi = GCTTheme.current.hostPalette
        if !ansi.isEmpty {
            return ansi[Int(host.gctHash % UInt32(ansi.count))]
        }
        return NSColor(gctHex: GroupStyle.palette[Int(host.gctHash) % GroupStyle.palette.count])
    }

}

extension PaneView {
    // Hit zones for manual routing (world coords).
    enum ResizeZone {
        case n, s, e, w, ne, nw, se, sw
    }

    func resizeZone(at worldPoint: CGPoint, screenTolerance t: CGFloat) -> ResizeZone? {
        let r = frame
        // grab zone so wide borders stay easy to catch zoomed out.
        let grab = max(t, GCTTheme.current.borderWidth)
        let inside = worldPoint.x >= r.minX - grab && worldPoint.x <= r.maxX + grab
            && worldPoint.y >= r.minY - grab && worldPoint.y <= r.maxY + grab
        guard inside,
              worldPoint.x <= r.minX + grab || worldPoint.x >= r.maxX - grab
                  || worldPoint.y <= r.minY + grab || worldPoint.y >= r.maxY - grab
        else { return nil }

        let nearW = abs(worldPoint.x - r.minX) <= grab
        let nearE = abs(worldPoint.x - r.maxX) <= grab
        let nearS = abs(worldPoint.y - r.minY) <= grab
        let nearN = abs(worldPoint.y - r.maxY) <= grab
        // Titlebar body moves: the top-edge strip overlaps the titlebar,
        // so a bare .n hit would steal titlebar grabs and bury the
        // titlebar right-click menu. Corners and side edges still resize;
        // the top-center band falls through to move.
        if worldPoint.y >= r.maxY - PaneView.titleBarHeight
            && worldPoint.y <= r.maxY
            && worldPoint.x >= r.minX && worldPoint.x <= r.maxX {
            if nearW && nearN { return .nw }
            if nearE && nearN { return .ne }
            if nearW { return .w }
            if nearE { return .e }
            return nil
        }
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

    func containsWorld(_ worldPoint: CGPoint, grab: CGFloat = 0) -> Bool {
        frame.insetBy(dx: -grab, dy: -grab).contains(worldPoint)
    }
    // World -> ghostty surface coords: top-left origin, points, chrome
    // excluded. Ghostty's own SurfaceView sends (x, height - y) relative
    // to its nsview; our manual routing must do the same or clicks and
    // selections land offset (border/titlebar) and vertically mirrored.
    func surfacePoint(at worldPoint: CGPoint) -> CGPoint {
        let lx = worldPoint.x - frame.minX - surfaceHostView.frame.minX
        let by = worldPoint.y - frame.minY - surfaceHostView.frame.minY
        return CGPoint(x: lx, y: surfaceHostView.bounds.height - by)
    }

    func surfaceContains(_ worldPoint: CGPoint) -> Bool {
        let p = surfacePoint(at: worldPoint)
        return p.x >= 0 && p.y >= 0
            && p.x <= surfaceHostView.bounds.width
            && p.y <= surfaceHostView.bounds.height
    }
}
