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

// Which half of `theme = light:x,dark:y` ghostty resolves to.
enum ColorScheme {
    case light, dark

    var ghostty: ghostty_color_scheme_e {
        self == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }
}

// Resolved colors from the finalized config (theme included), for the
// canvas and titlebar "ghostty" passthroughs. Nil where unset.
struct GhosttyColors {
    var background: NSColor?
    var foreground: NSColor?
    var titlebarBackground: NSColor?
    var titlebarForeground: NSColor?
}

final class GhosttyApp: @unchecked Sendable {
    private weak var delegate: (any GhosttyAppDelegate)?
    private(set) var app: UnsafeMutableRawPointer?
    private var config: UnsafeMutableRawPointer?
    private(set) var colors = GhosttyColors()

    init(delegate: any GhosttyAppDelegate) {
        self.delegate = delegate

        _ = ghostty_init(0, nil)

        let cfg = GhosttyApp.loadConfig()
        config = UnsafeMutableRawPointer(cfg)
        colors = GhosttyApp.colors(of: cfg)

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { ud in
            let me = Unmanaged<GhosttyApp>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async { me.pump() }
        }
        runtime.action_cb = { app, target, action in
            GhosttyApp.handleAction(app, target, action)
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

    // Base look first, then the user's own ghostty config wins on every
    // key it sets (config-file includes included below).
    private static func loadConfig() -> ghostty_config_t? {
        let cfg = ghostty_config_new()
        ghostty_config_load_file(cfg, GhosttyApp.baseConfigPath())
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        logDiagnostics(cfg)
        return cfg
    }

    // Keys the embedded ghostty rejected from the user's config (typos,
    // app-only options): surfaced so a "my setting does nothing" has an answer.
    private static func logDiagnostics(_ cfg: ghostty_config_t?) {
        let count = ghostty_config_diagnostics_count(cfg)
        for i in 0..<count {
            let d = ghostty_config_get_diagnostic(cfg, i)
            guard let msg = d.message else { continue }
            NSLog("[gct] ghostty config: \(String(cString: msg))")
        }
    }

    private static func colors(of cfg: ghostty_config_t?) -> GhosttyColors {
        GhosttyColors(
            background: color("background", of: cfg),
            foreground: color("foreground", of: cfg),
            titlebarBackground: color("window-titlebar-background", of: cfg),
            titlebarForeground: color("window-titlebar-foreground", of: cfg))
    }

    // False from ghostty_config_get = unset optional key.
    private static func color(_ key: String, of cfg: ghostty_config_t?) -> NSColor? {
        var color = ghostty_config_color_s()
        guard ghostty_config_get(cfg, &color, key, UInt(key.utf8.count)) else {
            return nil
        }
        return NSColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                       blue: CGFloat(color.b) / 255, alpha: 1)
    }

    // Re-read the ghostty config into every live surface (the app update
    // fans out), so reload-config swaps palette + font, not just chrome.
    func reloadConfig() {
        guard let app else { return }
        let cfg = GhosttyApp.loadConfig()
        ghostty_app_update_config(app, cfg)
        if let config { ghostty_config_free(config) }
        config = UnsafeMutableRawPointer(cfg)
    }

    // App-level scheme; new surfaces inherit it, live ones need
    // SurfaceHost.setColorScheme. ghostty answers via handleConfig.
    func setColorScheme(_ scheme: ColorScheme) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, scheme.ghostty)
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
    // ~/.config/ghostty/config still wins on every key. Colors ship as a
    // theme: ghostty replays explicit keys over themes, so a bare
    // `background` here would beat the user's `theme`.
    private static func baseConfigPath() -> String {
        let path = NSTemporaryDirectory() + "gct-ghostty-config"
        let cfg = """
        # Grand Central Terminal defaults
        theme = \(baseThemePath())
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

    private static func baseThemePath() -> String {
        let path = NSTemporaryDirectory() + "gct-ghostty-theme"
        let theme = """
        background = #000000
        foreground = #c8c8c8
        """
        try? Data(theme.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    // MARK: Actions from the core

    private static func handleAction(
        _ app: ghostty_app_t?,
        _ target: ghostty_target_s,
        _ action: ghostty_action_s
    ) -> Bool {
        if let ud = ghostty_app_userdata(app),
           Unmanaged<GhosttyApp>.fromOpaque(ud).takeUnretainedValue()
               .handleConfig(target, action) {
            return true
        }

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

    // Light/dark switch: ghostty asks for a soft reload (re-apply our
    // config under the new scheme), then the app reload reports the
    // resolved config, whose colors feed the canvas/titlebar passthroughs.
    // Hard reloads (ghostty's own keybind) stay unhandled.
    private func handleConfig(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            guard action.action.reload_config.soft else { return false }
            reapplyConfig(target)
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            guard target.tag == GHOSTTY_TARGET_APP else { return true }
            colors = GhosttyApp.colors(of: action.action.config_change.config)
            return true
        default:
            return false
        }
    }

    private func reapplyConfig(_ target: ghostty_target_s) {
        guard let config else { return }
        if target.tag == GHOSTTY_TARGET_SURFACE {
            ghostty_surface_update_config(target.target.surface, config)
            return
        }

        guard let app else { return }
        ghostty_app_update_config(app, config)
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
