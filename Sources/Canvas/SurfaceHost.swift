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

    private var surfaceStore: UnsafeMutableRawPointer?
    private let lock = NSLock()
    // Serial queue contract: ghostty_surface_write_output must be
    // serialized per surface. All feeds go through here.
    private let feedQueue = DispatchQueue(label: "canvas.surface.feed")

    init(paneID: PaneID, hostView: NSView, scale: Double, app: UnsafeMutableRawPointer?,
         delegate: any GhosttyAppDelegate) {
        self.paneID = paneID
        self.delegate = delegate

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(hostView).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = scale
        cfg.backend_type = GHOSTTY_BACKEND_EXTERNAL
        cfg.write_callback = { surface, data, len in
            guard let surface, let data, len > 0,
                  let host = SurfaceHost.from(surface) else { return }
            let bytes = Data(bytes: data, count: Int(len))  // copy before hops
            host.connSend?(host.paneID, bytes)
        }
        cfg.resize_callback = { surface, cols, rows, _, _ in
            guard let surface, let host = SurfaceHost.from(surface) else { return }
            DispatchQueue.main.async {
                host.delegate?.surfaceResize(host, cols, rows)
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
        guard let s = surfaceIfOpen() else { return }
        ghostty_surface_set_content_scale(s, scale, scale)
    }

    func setSize(width px: UInt32, height py: UInt32) {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen() else { return }
        ghostty_surface_set_size(s, px, py)
    }

    func setFocus(_ focused: Bool) {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen() else { return }
        ghostty_surface_set_focus(s, focused)
    }

    func key(_ event: ghostty_input_key_s) -> Bool {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen() else { return false }
        return ghostty_surface_key(s, event)
    }

    func text(_ str: String) {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen(), !str.isEmpty else { return }
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

    func mouseScroll(x: Double, y: Double, precision: Bool) {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen() else { return }
        var mods: ghostty_input_scroll_mods_t = 0
        if precision { mods |= 0b1 }
        ghostty_surface_mouse_scroll(s, x, y, mods)
    }

    func hasSelection() -> Bool {
        assert(Thread.isMainThread)
        guard let s = surfaceIfOpen() else { return false }
        return ghostty_surface_has_selection(s)
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
