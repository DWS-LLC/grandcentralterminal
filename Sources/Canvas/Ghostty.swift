// Global libghostty init: config, runtime callbacks, tick pump.

import AppKit
import CGhostty
import Common

protocol GhosttyAppDelegate: AnyObject {
    // Terminal grid changed (cols/rows) — forward to daemon TIOCSWINSZ.
    func surfaceResize(_ host: SurfaceHost, _ cols: UInt16, _ rows: UInt16)
    // Terminal wants its pane closed (shell exited or close request).
    func surfaceClose(_ host: SurfaceHost, confirmed: Bool)
    // Program title (OSC 0/2).
    func surfaceTitle(_ host: SurfaceHost, _ title: String)
    // Shell reported its cwd (OSC 7).
    func surfacePwd(_ host: SurfaceHost, _ pwd: String)
    // Bell.
    func surfaceBell(_ host: SurfaceHost)
}

final class GhosttyApp: @unchecked Sendable {
    private weak var delegate: (any GhosttyAppDelegate)?
    private(set) var app: UnsafeMutableRawPointer?
    private var config: UnsafeMutableRawPointer?
    // Resolved `background` from the finalized config (theme included), for
    // the canvas background's "ghostty" passthrough. Nil if unset.
    private(set) var background: NSColor?

    init(delegate: any GhosttyAppDelegate) {
        self.delegate = delegate

        _ = ghostty_init(0, nil)

        let cfg = ghostty_config_new()
        // Base look first, then the user's own ghostty config wins on
        // every key it sets (config-file includes included below).
        ghostty_config_load_file(cfg, GhosttyApp.baseConfigPath())
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        config = UnsafeMutableRawPointer(cfg)

        var color = ghostty_config_color_s()
        let bgKey = "background"
        if ghostty_config_get(cfg, &color, bgKey, UInt(bgKey.utf8.count)) {
            background = NSColor(
                red: CGFloat(color.r) / 255,
                green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255,
                alpha: 1)
        }

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { ud in
            let me = Unmanaged<GhosttyApp>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async { me.pump() }
        }
        runtime.action_cb = { _, target, action in
            GhosttyApp.handleAction(target, action)
        }
        runtime.read_clipboard_cb = { _, _, _, _, _, _ in
            // OSC 52 remote reads: unsupported.
            GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
        runtime.confirm_read_clipboard_cb = { _, _, request, _ in
            guard let request else { return }
            ghostty_surface_deny_clipboard_request(request, request)
        }
        runtime.write_clipboard_cb = { _, clipboard, contents, count, _ in
            GhosttyApp.writeClipboard(clipboard: clipboard, contents: contents, count: count)
        }
        runtime.close_surface_cb = { ud, confirmed in
            // Surface userdata is the owning SurfaceHost.
            let host = Unmanaged<SurfaceHost>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async {
                host.delegate?.surfaceClose(host, confirmed: confirmed)
            }
        }

        app = ghostty_app_new(&runtime, cfg)
        guard app != nil else {
            fatalError("ghostty_app_new failed")
        }

        // App mailbox pump.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.pump()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        if let config { ghostty_config_free(config) }
        if let app { ghostty_app_free(app) }
    }

    private func pump() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // Default config file: canvas look. Loaded before the user's config so
    // ~/.config/ghostty/config still wins on every key.
    private static func baseConfigPath() -> String {
        let path = NSTemporaryDirectory() + "gct-ghostty-config"
        let cfg = """
        # Grand Central Terminal defaults
        background = #000000
        foreground = #c8c8c8
        font-family = Menlo
        font-size = 13
        window-padding-x = 8
        window-padding-y = 6
        window-padding-balance = true
        cursor-style = block
        cursor-style-blink = true
        copy-on-select = false
        """
        try? Data(cfg.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    // MARK: Actions from the core

    private static func handleAction(
        _ target: ghostty_target_s,
        _ action: ghostty_action_s
    ) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let host = SurfaceHost.from(surface) else { return false }

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            if let t = action.action.set_title.title {
                host.delegate?.surfaceTitle(host, String(cString: t))
            }
            return true
        case GHOSTTY_ACTION_PWD:
            if let p = action.action.pwd.pwd {
                host.delegate?.surfacePwd(host, String(cString: p))
            }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            host.delegate?.surfaceBell(host)
            return true
        default:
            return false
        }
    }

    private static func writeClipboard(
        clipboard: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int
    ) {
        guard clipboard == GHOSTTY_CLIPBOARD_STANDARD,
              let contents, count > 0 else { return }
        for i in 0..<count {
            let c = contents[i]
            guard let mime = c.mime, strcmp(mime, "text/plain") == 0,
                  let data = c.data else { continue }
            let text = String(decoding: Data(bytes: data, count: c.len), as: UTF8.self)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            break
        }
    }
}
