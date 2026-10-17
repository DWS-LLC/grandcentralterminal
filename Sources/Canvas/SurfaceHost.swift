// Per-pane binding to a libghostty surface with an EXTERNAL termio backend:
// the daemon owns the PTY, we own rendering + VT state in-process.

import AppKit
import CGhostty
import Common

final class SurfaceHost: @unchecked Sendable {
    let paneID: PaneID
    weak var delegate: (any GhosttyAppDelegate)?
    // Set by CanvasView: keystrokes/encoded input -> daemon socket.
    var connSend: ((PaneID, Data) -> Void)?
    // Fires on real user input only (key/text), never on terminal auto-replies.
    var userInput: ((PaneID) -> Void)?

    private var surfaceStore: UnsafeMutableRawPointer?
    // Content scale the surface was last configured with; divides pixel
    // metrics back into points.
    private(set) var scale: Double
    // Vector zoom: the camera zoom this surface is rendered at, and the
    // exact content scale that kept its grid intact (nil = plain backing
    // scale). See renderZoom(_:base:points:).
    private(set) var zoom = 1.0
    private(set) var scaleOverride: Double?
    private weak var hostView: NSView?
    // Last occlusion state from the canvas; zoom re-renders hide and restore it.
    private var visible = true
    private let lock = NSLock()
    // Grid last reported to the daemon. Resize callbacks land on main
    // after the fact, so they report the grid as it is NOW: a zoom
    // re-render that probes scales and settles on the same grid sends
    // nothing, only a real change goes out.
    private var reportedGrid: (cols: UInt16, rows: UInt16)?
    // Serial queue contract: ghostty_surface_write_output must be
    // serialized per surface. All feeds go through here.
    private let feedQueue = DispatchQueue(label: "gct.surface.feed")

    // fontSize: inherited zoom in points (0 = config default). Pass the
    // focused surface's ghostty_surface_inherited_config(...).font_size
    // so cmd-+/- zoom carries to new panes.
    init(paneID: PaneID, hostView: NSView, scale: Double, app: UnsafeMutableRawPointer?,
         delegate: any GhosttyAppDelegate, fontSize: Float = 0) {
        self.paneID = paneID
        self.delegate = delegate
        self.scale = scale
        self.hostView = hostView

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(hostView).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = scale
        cfg.font_size = fontSize
        cfg.backend_type = GHOSTTY_BACKEND_EXTERNAL
        cfg.write_callback = { surface, data, len in
            guard let surface, let data, len > 0,
                  let host = SurfaceHost.from(surface) else { return }
            let bytes = Data(bytes: data, count: Int(len))  // copy before hops
            host.connSend?(host.paneID, bytes)
        }
        cfg.resize_callback = { surface, _, _, _, _ in
            guard let surface, let host = SurfaceHost.from(surface) else { return }
            DispatchQueue.main.async {
                host.reportIfMoved()
            }
        }

        // ghostty_surface_new is main-thread only.
        assert(Thread.isMainThread)
        surfaceStore = ghostty_surface_new(app, &cfg)
        guard surfaceStore != nil else {
            fatalError("ghostty_surface_new failed")
        }
    }

    static func from(_ surface: UnsafeMutableRawPointer?) -> SurfaceHost? {
        guard let surface, let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<SurfaceHost>.fromOpaque(ud).takeUnretainedValue()
    }

    func surfaceIfOpen() -> UnsafeMutableRawPointer? {
        lock.withLock { surfaceStore }
    }

    // MARK: IO (thread-safe)

    func feed(_ data: Data) {
        // Called from the socket reader thread; serialize onto feedQueue.
        feedQueue.async { [weak self] in
            guard let self, let s = self.surfaceIfOpen() else { return }
            data.withUnsafeBytes { raw in
                ghostty_surface_write_output(s, raw.baseAddress!
                    .assumingMemoryBound(to: CChar.self), UInt(raw.count))
            }
        }
    }

    // MARK: Main-thread surface API

    func setScale(_ scale: Double) {
        assert(Thread.isMainThread)
        self.scale = scale
        guard let s = surfaceIfOpen() else { return }
        ghostty_surface_set_content_scale(s, scale, scale)
    }

    // Tell the daemon only when the grid really moved.
    private func reportIfMoved() {
        guard let g = grid() else { return }
        guard reportedGrid?.cols != g.cols || reportedGrid?.rows != g.rows else { return }
        reportedGrid = (g.cols, g.rows)
        delegate?.surfaceResize(self, g.cols, g.rows)
    }

    private func grid() -> (cols: UInt16, rows: UInt16)? {
        guard let s = surfaceIfOpen() else { return nil }
        let size = ghostty_surface_size(s)
        return (size.columns, size.rows)
    }

    // Content scales tried around the ideal one, in order (fractions).
    // Cell pixels are whole numbers, so the exact camera scale can shift
    // the grid by a column; a nudge of a few percent keeps it.
    private static let scaleNudges: [Double] =
        [0, 0.005, -0.005, 0.01, -0.01, 0.015, -0.015, 0.02, -0.02, 0.03, -0.03, 0.04, -0.04]
    private static let unitZoomTolerance = 0.01

    enum ZoomFit { case applied, gridUnstable }

    // Vector zoom: re-render at `base * zoom` (fonts re-rasterized, not
    // magnified). The layer is the IOSurface itself and its drawable is
    // bounds * contentsScale, so the layer scale follows. The grid must
    // not change (a SIGWINCH per zoom step would redraw tmux): probe
    // nearby scales until it matches, else restore and report unstable.
    func renderZoom(_ zoom: Double, base: Double, points: CGSize) -> ZoomFit {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen(), let target = grid() else { return .gridUnstable }

        // No flashing: while probing, the renderer is told it is hidden so
        // it draws nothing mid-probe (its mailbox applies font + size in
        // order, then the visible message redraws once with the final
        // state); one CATransaction so the layer commits once; the old
        // frame is stretched to the new bounds until the new one lands.
        ghostty_surface_set_occlusion(s, false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostView?.layer?.contentsGravity = .resize

        // Probes never reach the terminal: each apply() passes through
        // transient grids (new scale at old pixels = cols / zoom), and a
        // reflow there is lossy. The program never gets a SIGWINCH to
        // repaint, so its cursor math drifts (doubled lines, cursor a row
        // low). Release sends only the final size.
        ghostty_surface_hold_resize(s, true)
        defer {
            ghostty_surface_hold_resize(s, false)
            CATransaction.commit()
            ghostty_surface_set_occlusion(s, visible)
            restoreGravityLater()
        }

        // Back at 1x: exact backing scale, whatever grid that yields.
        if abs(zoom - 1) < Self.unitZoomTolerance {
            apply(scale: base, points: points)
            self.zoom = 1
            scaleOverride = nil
            return .applied
        }

        let prior = scale
        for nudge in Self.scaleNudges {
            let candidate = base * zoom * (1 + nudge)
            apply(scale: candidate, points: points)
            guard let g = grid(), g.cols == target.cols, g.rows == target.rows else { continue }

            self.zoom = zoom
            scaleOverride = candidate
            return .applied
        }

        apply(scale: prior, points: points)
        return .gridUnstable
    }

    // ghostty pins top-left gravity so resizes never stretch; put it back
    // once the re-rendered frame has had time to land.
    private static let gravityRestoreDelay: TimeInterval = 0.3
    private var gravityWork: DispatchWorkItem?

    private func restoreGravityLater() {
        gravityWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hostView?.layer?.contentsGravity = .topLeft
        }
        gravityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gravityRestoreDelay, execute: work)
    }

    private func apply(scale sc: Double, points: CGSize) {
        hostView?.layer?.contentsScale = sc
        setScale(sc)
        setSize(width: UInt32(max(1, points.width * sc)),
                height: UInt32(max(1, points.height * sc)))
    }

    func setSize(width px: UInt32, height py: UInt32) {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen() else { return }
        ghostty_surface_set_size(s, px, py)
    }

    // Current grid + cell metrics. Cell pixels are at the surface's
    // content scale; divide by `scale` for points. Nil while closed or
    // before the font metrics exist.
    func surfaceMetrics() -> (cols: UInt16, rows: UInt16,
                              cellWidth: Double, cellHeight: Double)? {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen() else { return nil }
        let size = ghostty_surface_size(s)
        guard size.cell_width_px > 0, size.cell_height_px > 0, scale > 0 else {
            return nil
        }
        return (size.columns, size.rows,
                Double(size.cell_width_px) / scale, Double(size.cell_height_px) / scale)
    }

    // Renderer pause: ghostty stops the surface's DisplayLink while
    // occluded (zero presents, VT keeps flowing). Drive from canvas
    // visibility: off-screen panes, miniaturized/hidden window.
    func setOcclusion(_ visible: Bool) {
        assert(Thread.isMainThread)
        self.visible = visible
        guard let s = surfaceIfOpen() else { return }
        ghostty_surface_set_occlusion(s, visible)
    }

     func setFocus(_ focused: Bool) {
         assert(Thread.isMainThread)
         guard let s = surfaceIfOpen() else { return }
         ghostty_surface_set_focus(s, focused)
     }

    // macOS virtual keycodes of modifier-only keys (shift, ctrl, alt,
    // cmd, caps lock, fn): pressing them is not typing.
    private static let modifierKeycodes: Set<UInt32> =
        [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]

    // Typing = a key press/repeat that isn't a bare modifier or a Cmd
    // shortcut (Cmd+C, Cmd+Tab are app actions, not input to the pane).
    private static func isTyping(_ event: ghostty_input_key_s) -> Bool {
        if event.action == GHOSTTY_ACTION_RELEASE { return false }
        if event.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { return false }
        return !modifierKeycodes.contains(event.keycode)
    }

    func key(_ event: ghostty_input_key_s) -> Bool {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen() else { return false }
        if Self.isTyping(event) {
            userInput?(paneID)
        }
        return ghostty_surface_key(s, event)
    }

    func text(_ str: String) {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen(), !str.isEmpty else { return }
        userInput?(paneID)
        str.withCString { ptr in
            ghostty_surface_text(s, ptr, UInt(strlen(ptr)))
        }
    }

    func mouseButton(_ state: ghostty_input_mouse_state_e,
                     _ button: ghostty_input_mouse_button_e,
                     _ mods: ghostty_input_mods_e) {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen() else { return }
        _ = ghostty_surface_mouse_button(s, state, button, mods)
    }

    func mousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen() else { return }
        ghostty_surface_mouse_pos(s, x, y, mods)
    }

    func mouseScroll(x: Double, y: Double, mods: ghostty_input_scroll_mods_t) {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen() else { return }
        ghostty_surface_mouse_scroll(s, x, y, mods)
    }

    func hasSelection() -> Bool {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen() else { return false }
        return ghostty_surface_has_selection(s)
    }

    // Cursor point for anchoring the IME composition window: surface points,
    // top-left origin (points, not pixels — ghostty divides out content scale).
    func imePoint() -> (x: Double, y: Double, width: Double, height: Double)? {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen() else { return nil }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(s, &x, &y, &w, &h)
        return (x, y, w, h)
    }

    // Copy the current selection to the pasteboard; returns the text.
    func copySelection() -> String? {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen(),
              ghostty_surface_has_selection(s) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(s, &text) else { return nil }
        defer { ghostty_surface_free_text(s, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return nil }
        return String(decoding: Data(bytes: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    // Must not race feed: drain the feed queue, then free.
    func close() {
        assert(Thread.isMainThread)
        feedQueue.sync {
            if let s = self.surfaceIfOpen() {
                ghostty_surface_free(s)
                self.lock.lock()
                self.surfaceStore = nil
                self.lock.unlock()
            }
        }
    }
}
