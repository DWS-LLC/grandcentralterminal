// ~/.config/gct/config.toml: appearance + keybind configuration.
//
// Created with defaults on first launch. Unknown keys are ignored so older
// builds keep working against newer configs; malformed values fall back to
// their defaults. Most keys apply live via the reload-config action
// (cmd+shift+r); doom's structural keys (enabled, start-hidden,
// launch-at-login) need a relaunch.
import AppKit
import Common

// MARK: - Minimal TOML

// Just enough TOML for this schema: [tables], `key = value`, basic/literal
// strings, bare tokens (numbers, booleans, enums), and # comments.
enum TOML {
    // section name -> key -> raw value token. Root keys live under "".
    static func parse(_ text: String) -> [String: [String: String]] {
        var tables: [String: [String: String]] = ["": [:]]
        var section = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { continue }
                section = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                if tables[section] == nil { tables[section] = [:] }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else { continue }
            if let value = parseValue(String(line[line.index(after: eq)...])) {
                tables[section]?[key] = value
            }
        }
        return tables
    }

    // Cut at the first # that isn't inside a quoted string.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for (i, c) in line.enumerated() {
            if escaped { escaped = false; continue }
            if let q = quote {
                if c == "\\" { escaped = true }
                else if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" {
                return String(line[..<line.index(line.startIndex, offsetBy: i)])
            }
        }
        return line
    }

    private static func parseValue(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        if v.hasPrefix("\"") { return basicString(v) }
        if v.hasPrefix("'") {
            guard let end = v.dropFirst().firstIndex(of: "'") else { return nil }
            return String(v[v.index(after: v.startIndex)..<end])
        }
        // Bare token: number, boolean, or enum word.
        let token = v.prefix { !$0.isWhitespace }
        return token.isEmpty ? nil : String(token)
    }

    // Basic string with the common escapes (\n \t \r \" \\ \uXXXX).
    private static func basicString(_ v: String) -> String? {
        guard let end = closingQuote(v) else { return nil }
        let body = String(v[v.index(after: v.startIndex)..<end])
        var out = ""
        var it = body.makeIterator()
        while let c = it.next() {
            if c != "\\" { out.append(c); continue }
            guard let e = it.next() else { return nil }
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\"", "\\": out.append(e)
            case "u":
                var hex = ""
                for _ in 0..<4 { if let h = it.next() { hex.append(h) } }
                if let cp = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(cp) {
                    out.unicodeScalars.append(scalar)
                }
            default: return nil
            }
        }
        return out
    }

    private static func closingQuote(_ v: String) -> String.Index? {
        var i = v.index(after: v.startIndex)
        while i < v.endIndex {
            if v[i] == "\\" {
                i = v.index(i, offsetBy: 2, limitedBy: v.endIndex) ?? v.endIndex
                continue
            }
            if v[i] == "\"" { return i }
            i = v.index(after: i)
        }
        return nil
    }
}

// MARK: - Color helpers

extension NSColor {
    // "#rgb" / "#rrggbb" / "#rgba" / "#rrggbbaa" (leading # optional);
    // nil unless valid hex. Alpha 1 unless the 4/8-digit form gives one.
    convenience init?(gctHex hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(
                red: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: 1)
        } else {
            self.init(
                red: CGFloat((v >> 24) & 0xFF) / 255,
                green: CGFloat((v >> 16) & 0xFF) / 255,
                blue: CGFloat((v >> 8) & 0xFF) / 255,
                alpha: CGFloat(v & 0xFF) / 255)
        }
    }

    // "#rrggbb" in sRGB (alpha dropped).
    var gctHexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let channel = { (v: CGFloat) in Int((v * 255).rounded()) }
        return String(format: "#%02x%02x%02x", channel(c.redComponent),
                      channel(c.greenComponent), channel(c.blueComponent))
    }

    // Rec. 601 luminance in 0...1, sRGB components.
    var gctLuminance: Double {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.299 * Double(c.redComponent)
            + 0.587 * Double(c.greenComponent)
            + 0.114 * Double(c.blueComponent)
    }
}

extension String {
    // FNV-1a: String.hashValue is seeded per process, this isn't. Keeps
    // hashed colors (hosts, groups) stable across launches and machines.
    var gctHash: UInt32 {
        utf8.reduce(2166136261) { ($0 ^ UInt32($1)) &* 16777619 }
    }
}

// A color spec split per mode. Config keys: `key` (both modes),
// `key-dark` / `key-light` (win over `key` in their mode).
struct GCTModeColor: Equatable {
    var shared: String?
    var dark: String?
    var light: String?

    func spec(dark isDark: Bool) -> String? {
        (isDark ? dark : light) ?? shared
    }
}

// MARK: - Keybinds

// App shortcuts ("cmd+t", "ctrl+shift+k", "a"). Character-based: the last
// + separated part is the key, everything before it is modifiers.
struct GCTKeybind {
    let mods: NSEvent.ModifierFlags
    let key: String
    // Virtual keycode on a US layout, for RegisterEventHotKey. Nil when
    // the key has no known code (matches() still works for single chars).
    let carbonKeyCode: UInt32?

    init?(_ spec: String) {
        var mods: NSEvent.ModifierFlags = []
        var parts = spec.lowercased().split(separator: "+").map(String.init)
        guard !parts.isEmpty else { return nil }
        let name = parts.removeLast()
        guard !name.isEmpty else { return nil }
        for part in parts {
            switch part {
            case "cmd", "super": mods.insert(.command)
            case "ctrl", "control": mods.insert(.control)
            case "alt", "opt", "option": mods.insert(.option)
            case "shift": mods.insert(.shift)
            default: return nil
            }
        }
        self.mods = mods
        if let named = Self.namedKeys[name] {
            key = named.match
            carbonKeyCode = named.code
        } else if name.count == 1 {
            key = name
            carbonKeyCode = Self.usKeyCode(for: name)
        } else {
            return nil
        }
    }

    // Exact modifier-set match, so cmd+k doesn't fire on cmd+shift+k.
    func matches(_ event: NSEvent) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(relevant) == mods.intersection(relevant),
              let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return chars == key
    }

    // In-app shortcut match: characters, or the virtual keycode for named
    // keys without one (arrows, F-keys).
    func matchesLocal(_ event: NSEvent) -> Bool {
        matches(event) || (key.isEmpty && matchesKeyCode(event))
    }

    // Carbon modifiers for RegisterEventHotKey (HIToolbox values:
    // cmdKey 1<<8, shiftKey 1<<9, optionKey 1<<11, controlKey 1<<12).
    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if mods.contains(.command) { m |= 1 << 8 }
        if mods.contains(.shift) { m |= 1 << 9 }
        if mods.contains(.option) { m |= 1 << 11 }
        if mods.contains(.control) { m |= 1 << 12 }
        return m
    }

    // Named non-character keys: match string for matches() ("" never
    // matches locally; these are Carbon-only) + US virtual keycode.
    private static let namedKeys: [String: (match: String, code: UInt32)] = [
        "space": (" ", 49),
        "tab": ("\t", 48),
        "return": ("\r", 36),
        "enter": ("\r", 36),
        "escape": ("\u{1b}", 53),
        "esc": ("\u{1b}", 53),
        "delete": ("\u{7f}", 51),
        "backspace": ("\u{7f}", 51),
        "left": ("", 123), "right": ("", 124),
        "down": ("", 125), "up": ("", 126),
        "f1": ("", 122), "f2": ("", 120),
        "f3": ("", 99), "f4": ("", 118),
        "f5": ("", 96), "f6": ("", 97),
        "f7": ("", 98), "f8": ("", 100),
        "f9": ("", 101), "f10": ("", 109),
        "f11": ("", 103), "f12": ("", 111),
    ]

    // US ANSI layout: single character -> virtual keycode.
    private static func usKeyCode(for key: String) -> UInt32? {
        switch key {
        case "a": return 0
        case "s": return 1
        case "d": return 2
        case "f": return 3
        case "h": return 4
        case "g": return 5
        case "z": return 6
        case "x": return 7
        case "c": return 8
        case "v": return 9
        case "b": return 11
        case "q": return 12
        case "w": return 13
        case "e": return 14
        case "r": return 15
        case "y": return 16
        case "t": return 17
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "6": return 22
        case "5": return 23
        case "=": return 24
        case "9": return 25
        case "7": return 26
        case "-": return 27
        case "8": return 28
        case "0": return 29
        case "]": return 30
        case "o": return 31
        case "u": return 32
        case "[": return 33
        case "i": return 34
        case "p": return 35
        case "l": return 37
        case "j": return 38
        case "'": return 39
        case "k": return 40
        case ";": return 41
        case "\\": return 42
        case ",": return 43
        case "/": return 44
        case "n": return 45
        case "m": return 46
        case ".": return 47
        case "`": return 50
        default: return nil
        }
    }
}

// Which side of the focused pane cmd+t opens on.
enum GCTNewWindowDirection: String {
    case above, below, left, right
}

// Which anchors window snapping locks: edges (min/max), centers (mid),
// or all of them. Resize always uses the moving edge; this picks the
// foreign anchors it can land on (and the move anchors).
enum GCTSnapType: String {
    case all, center, edges
}

// Size of new panes: follows the focused pane, or a fixed terminal grid.
enum GCTNewWindowDim: Equatable {
    case follows
    case fixed(cols: Int, rows: Int)

    // "follows", or "cols,rows" ("80,30", bare or quoted). Anything
    // malformed falls back to follows.
    static func parse(_ raw: String) -> GCTNewWindowDim {
        let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if v == "follows" || v == "default" { return .follows }
        let parts = v.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2, let cols = Int(parts[0]), let rows = Int(parts[1]),
              (1...1000).contains(cols), (1...1000).contains(rows) else {
            return .follows
        }
        return .fixed(cols: cols, rows: rows)
    }
}

// Camera response to a mouse click that moves focus to another pane.
enum GCTClickCamera: String {
    case none, center, fit
}

// Screen-space status bar edge.
enum GCTStatusbarPosition: String {
    case top, bottom
}

// Doom mode: show/hide animation for the summoned canvas.
enum DoomAnimation: String {
    case slide, fade
}

// Which screen a summoned doom window appears on.
enum DoomScreen: String {
    case mouse, main, menubar
}

// [doom] section: on by default — GCT is a background daemon app and the
// global hotkey summons it. Hotkey-only visibility: panning the canvas
// never hides it.
struct GCTDoom {
    var enabled = true
    var toggle: GCTKeybind? = GCTKeybind("ctrl+space")
    var animation = DoomAnimation.fade
    var animationDuration = 0.2
    var screen = DoomScreen.mouse
    var startHidden = true
    var launchAtLogin = false
}

enum GCTAction: String, CaseIterable {
    case newPane = "new-pane"
    case closePane = "close-pane"
    case renamePane = "rename-pane"
    // Declared before switcher so the cmd+h/j/k/l defaults win key ties
    // against a stale config that still pins switcher to cmd+k.
    case moveFocusAbove = "move-focus-above"
    case moveFocusBelow = "move-focus-below"
    case moveFocusLeft = "move-focus-left"
    case moveFocusRight = "move-focus-right"
    case openNewAbove = "open-new-window-above"
    case openNewBelow = "open-new-window-below"
    case openNewLeft = "open-new-window-left"
    case openNewRight = "open-new-window-right"
    case growAbove = "grow-window-above"
    case growBelow = "grow-window-below"
    case growLeft = "grow-window-left"
    case growRight = "grow-window-right"
    case shrinkAbove = "shrink-window-above"
    case shrinkBelow = "shrink-window-below"
    case shrinkLeft = "shrink-window-left"
    case shrinkRight = "shrink-window-right"
    case switcher = "switcher"
    case fitAll = "fit-all"
    case zoomPane = "zoom-pane"
    case cameraZoomPane = "camera-zoom-pane"
    case copy = "copy"
    case paste = "paste"
    case groupSelection = "group-selection"
    case ungroup = "ungroup"
    case toggleFloating = "toggle-floating"
    case togglePaneSelection = "toggle-pane-selection"
    case clearPaneSelection = "clear-pane-selection"
    case toggleSnapping = "toggle-snapping"
    case moveWindowToSnap = "move-window-to-snap"
    case reloadConfig = "reload-config"
    case relaxLayout = "relax-layout"
}
// MARK: - Config

struct GCTConfig {
    static var current = GCTConfig()

    var appearance: GCTAppearance = .system
    // Color specs: nil = mode default, "ghostty" = ghostty's background, else hex.
    var backgroundDark: String?
    var backgroundLight: String?
    // ShaderToy GLSL drawn as the canvas (absolute path, nil = plain color),
    // its frame rate cap, and render resolution as a fraction of native.
    var backgroundShader: String?
    var backgroundShaderFPS = 60
    var backgroundShaderScale: CGFloat = 1
    // Height in points of the fade from the canvas into the menubar.
    var topFade: CGFloat = 32
    // Fade hugs the menubar (exponential) instead of a smoothstep ramp.
    var topFadeExp = true
    var titlebarBackground = GCTModeColor()
    var titlebarText = GCTModeColor()
    // Border fill (default: the titlebar background), selection/zoom
    // accent, and drop shadow color.
    var titlebarBorder = GCTModeColor()
    var accent = GCTModeColor()
    var shadowColor = GCTModeColor()
    var titlebarFont: String?
    var titlebarFontSize: CGFloat = 12
    // Pane chrome: border on the left/right/bottom edges in points (the
    // top edge hides behind the titlebar itself; same color as the
    // titlebar), plus the drop shadow. shadow-opacity 0 turns it off.
    var titlebarBorderWidth: CGFloat = 4
    var shadowOpacity: Float = 0.55
    var shadowRadius: CGFloat = 12
    var keybinds: [GCTAction: GCTKeybind] = GCTConfig.defaultKeybinds
    // Panes are kept from overlapping: creation, moves, and resizes all
    // resolve collisions.
    var allowWindowOverlap = false
    // Mouse drags never shove other panes/groups out of the way (they
    // slide around or hold instead). Keyboard grow always shoves.
    var allowMouseDragToPush = false
    // Minimum padding between windows in world points (0-256, default
    // 0 = flush). Collision resolves (create/move/resize, keyboard
    // grow, group shoves) keep at least this much air; snapping still
    // lands flush, then the gap resolve pushes back out to the gap.
    // Raising it re-spreads existing panes on reload-config (and on
    // next launch); lowering it only affects future moves.
    var windowGap: CGFloat = 0
    // Magnetic window snapping: dragging or resizing a pane within
    // snap-radius pulls it flush with nearby panes and lights
    // full-canvas guide lines. On by default; the toggle-snapping
    // keybind flips it at runtime (never re-lays-out existing panes).
    var snapping = true
    // Which anchors lock: edges (min/max, default), center (mid), or
    // all. Resize always uses the moving edge; this picks the foreign
    // anchors it (and moves) can land on.
    var snappingType = GCTSnapType.edges
    // Snap radius in screen points (constant feel at any zoom).
    var snapRadius: CGFloat = 16
    // Guide lines: show-snap-guides = false hides them; snap-guide-color
    // tints them (hex like "#ff453a", "default" for translucent ghostty
    // foreground, "none" to hide).
    var showSnapGuides = true
    var snapGuideColor = GCTModeColor()
    var newWindowDirection = GCTNewWindowDirection.right
    // Size of new panes: focused pane's size, or a fixed cols x rows grid
    // (80x24 when the canvas is empty).
    var newWindowDim = GCTNewWindowDim.follows
    // Keyboard resize step: one cell when measurable (col width / row
    // height), else resize-step-points. resize-step-cells scales the cell
    // step (e.g. 2 = two cells per press).
    var resizeStepCells = 1
    var resizeStepPoints: CGFloat = 40
    // Animate the camera to a pane created from this canvas (cmd+t,
    // open-new-window-*, drag-to-create, right-click menu).
    var moveFocusOnNewWindow = true
    // Clicking another pane to focus it: leave the camera, center it, or
    // zoom to fit it. Applied on release, and only for a click (a drag
    // never moves the camera under the cursor).
    var cameraOnFocusClick = GCTClickCamera.center
    // Directional focus moves (cmd+h/j/k/l): center the newly focused
    // pane, and/or zoom to fit it. Independent; both default true (fit
    var cameraFollowsFocusMove = true
    var cameraFitsFocusMove = true
    // cmd+h/j/k/l remember where you came from: the opposite key goes
    // back, staggered layouts included.
    var focusMoveMemory = true
    // Zoom to fit a pane after resizing it (mouse or keyboard).
    var cameraFitsResize = true
    // Camera fits and centering dodge the system picture-in-picture
    // window: panes land in the free strip beside it, not under it.
    var pipAware = true
    // cmd+z fullscreen follows the same rule (needs pip-aware too).
    var pipAwareZoom = true
    // Unfocused panes that have gone quiet fade by this much (0 = off).
    var dimInactive = 0.35
    // Seconds of silence before an unfocused pane dims; output wakes it.
    var dimDelay = 4.0
    // Desktop notifications: OSC 9/777, bell, OSC 7501 blocked/done/error,
    // and `gctd notify`, from panes you are not looking at.
    var notifications = true
    // Cables between a pane and the panes it spawned, with slidable ties.
    var cables = true
    // Hover behavior: focus-follows-mouse focuses the pane under the
    // cursor on motion (same name as ghostty); scroll-on-terminal-hover
    // routes wheel/trackpad scroll to the hovered terminal, else pan
    // (trackpad) or zoom (wheel). Both default true: scroll over a
    // terminal scrolls it, scroll over empty canvas pans/zooms.
    var focusFollowsMouse = false
    var scrollOnTerminalHover = true
    // Canvas zoom limits (wheel/pinch), world scale where 1.0 = actual
    // size. max > 1 magnifies the terminal raster (slightly soft);
    // per-pane cmd-+/- stays sharp.
    var zoomMin: CGFloat = 0.03
    var zoomMax: CGFloat = 4.0
    // Camera glide length (focus moves, fit-all, gctd camera default).
    var cameraAnimDuration: Double = 0.28
    // Screen-space overlay bar of xbar-compatible plugin components.
    // Off by default; top/bottom edge; components lists plugin
    // basenames with `gap` spacers absorbing leftover width.
    var statusbarEnabled = false
    var statusbarPosition = GCTStatusbarPosition.bottom
    var statusbarComponents: [String] = ["clock", "gap"]
    var statusbarHeight: CGFloat = 26
    var statusbarSpacing: CGFloat = 8
    var statusbarBackground = GCTModeColor()
    var statusbarText = GCTModeColor()
    // Pane switcher overlay (cmd+p style): panel, outline, row text, and
    // the most-recent row's text.
    var switcherBackground = GCTModeColor()
    var switcherBorder = GCTModeColor()
    var switcherText = GCTModeColor()
    var switcherTextActive = GCTModeColor()
    var statusbarFont: String?
    var statusbarFontSize: CGFloat = 12
    var statusbarOpacity: CGFloat = 1
    var doom = GCTDoom()
    // Remote daemons: one [host.<name>] table each (name = canvas label).
    // host = TCP address, port defaults to 7420, token must match the
    // daemon's --token/GCT_TOKEN, color tints that host's window chrome.
    var remotes: [GCTRemoteHost] = []

    // GCT_CONFIG_DIR swaps the whole config dir (config.toml + statusbar/)
    // so a demo/test canvas runs beside the live one. Unset = ~/.config/gct.
    static let dir: String = ProcessInfo.processInfo.environment["GCT_CONFIG_DIR"]
        ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/gct")
    static let path: String = (dir as NSString).appendingPathComponent("config.toml")

    // Read the config file, creating it with defaults if missing.
    static func load() -> GCTConfig {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            // Unreadable (non-UTF-8 save, perms): keep what we have. Never
            // overwrite a user's file with the template.
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                NSLog("[gct] \(path) unreadable (UTF-8 only) — keeping current config")
                return current
            }
            return parse(text)
        }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            atPath: dir.path, withIntermediateDirectories: true)
        try? template.data(using: .utf8)?.write(to: url)
        return parse(template)
    }

    static func parse(_ text: String) -> GCTConfig {
        var cfg = GCTConfig()
        let t = TOML.parse(text)
        let root = t[""] ?? [:]

        if let a = root["appearance"], let mode = GCTAppearance(rawValue: a.lowercased()) {
            cfg.appearance = mode
        }

        if let v = root["allow-window-overlap"] {
            cfg.allowWindowOverlap = flag(v, cfg.allowWindowOverlap)
        }
        if let v = root["allow-mouse-drag-to-push"] {
            cfg.allowMouseDragToPush = flag(v, cfg.allowMouseDragToPush)
        }
        if let s = root["window-gap"], let n = Double(s),
           (0.0...256.0).contains(n) {
            cfg.windowGap = CGFloat(n)
        }
        if let v = root["snapping"] {
            cfg.snapping = flag(v, cfg.snapping)
        }
        if let v = root["snapping-type"],
           let t = GCTSnapType(rawValue: v.lowercased()) {
            cfg.snappingType = t
        }
        if let s = root["snap-radius"], let n = Double(s),
           (2.0...128.0).contains(n) {
            cfg.snapRadius = CGFloat(n)
        }
        if let v = root["show-snap-guides"] {
            cfg.showSnapGuides = flag(v, cfg.showSnapGuides)
        }
        cfg.snapGuideColor = modeColor(root, "snap-guide-color")
        if let v = root["new-window-open-direction"],
           let d = GCTNewWindowDirection(rawValue: v.lowercased()) {
            cfg.newWindowDirection = d
        }
        if let v = root["new-window-dim"] {
            cfg.newWindowDim = GCTNewWindowDim.parse(v)
        }
        if let v = root["resize-step-cells"], let n = Int(v), (1...16).contains(n) {
            cfg.resizeStepCells = n
        }
        if let v = root["resize-step-points"], let n = Double(v),
           (1.0...1000.0).contains(n) {
            cfg.resizeStepPoints = CGFloat(n)
        }
        if let v = root["move-focus-on-new-window"] {
            cfg.moveFocusOnNewWindow = flag(v, cfg.moveFocusOnNewWindow)
        }
        if let v = root["camera-follows-focus-move"] {
            cfg.cameraFollowsFocusMove = flag(v, cfg.cameraFollowsFocusMove)
        }
        if let v = root["camera-fits-focus-move"] {
            cfg.cameraFitsFocusMove = flag(v, cfg.cameraFitsFocusMove)
        }
        if let v = root["focus-move-memory"] {
            cfg.focusMoveMemory = flag(v, cfg.focusMoveMemory)
        }
        if let v = root["camera-fits-resize"] {
            cfg.cameraFitsResize = flag(v, cfg.cameraFitsResize)
        }
        if let v = root["pip-aware"] {
            cfg.pipAware = flag(v, cfg.pipAware)
        }
        if let v = root["pip-aware-zoom"] {
            cfg.pipAwareZoom = flag(v, cfg.pipAwareZoom)
        }
        if let s = root["dim-inactive"], let n = Double(s), (0.0...0.9).contains(n) {
            cfg.dimInactive = n
        }
        if let s = root["dim-delay"], let n = Double(s), (0.0...3600.0).contains(n) {
            cfg.dimDelay = n
        }
        if let v = root["notifications"] {
            cfg.notifications = flag(v, cfg.notifications)
        }
        if let v = root["cables"] {
            cfg.cables = flag(v, cfg.cables)
        }
        if let v = root["camera-on-focus-click"],
           let c = GCTClickCamera(rawValue: v.lowercased()) {
            cfg.cameraOnFocusClick = c
        }
        if let v = root["focus-follows-mouse"] {
            cfg.focusFollowsMouse = flag(v, cfg.focusFollowsMouse)
        }
        if let v = root["scroll-on-terminal-hover"] {
            cfg.scrollOnTerminalHover = flag(v, cfg.scrollOnTerminalHover)
        }
        if let s = root["zoom-min"], let n = Double(s), (0.005...1.0).contains(n) {
            cfg.zoomMin = CGFloat(n)
        }
        if let s = root["zoom-max"], let n = Double(s), (1.0...8.0).contains(n) {
            cfg.zoomMax = CGFloat(n)
        }
        if cfg.zoomMin > cfg.zoomMax { cfg.zoomMin = min(cfg.zoomMax, 1.0) }
        if let s = root["camera-animation-duration"], let n = Double(s),
           (0.05...10.0).contains(n) {
            cfg.cameraAnimDuration = n
        }
        let sb = t["statusbar"] ?? [:]
        if let v = sb["enabled"] {
            cfg.statusbarEnabled = flag(v, cfg.statusbarEnabled)
        }
        if let v = sb["position"],
           let p = GCTStatusbarPosition(rawValue: v.lowercased()) {
            cfg.statusbarPosition = p
        }
        if let v = sb["components"], !v.isEmpty {
            let parts = v.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            if !parts.isEmpty { cfg.statusbarComponents = parts }
        }
        if let s = sb["height"], let n = Double(s), (16.0...64.0).contains(n) {
            cfg.statusbarHeight = CGFloat(n)
        }
        if let s = sb["spacing"], let n = Double(s), (0.0...64.0).contains(n) {
            cfg.statusbarSpacing = CGFloat(n)
        }
        if let s = sb["opacity"], let n = Double(s), (0.0...1.0).contains(n) {
            cfg.statusbarOpacity = CGFloat(n)
        }
        cfg.statusbarBackground = modeColor(sb, "background")
        cfg.statusbarText = modeColor(sb, "text")
        if let f = sb["font"], f.lowercased() != "default" {
            cfg.statusbarFont = f
        }
        if let s = sb["font-size"], let n = Double(s), (6.0...48.0).contains(n) {
            cfg.statusbarFontSize = CGFloat(n)
        }

        let sw = t["switcher"] ?? [:]
        cfg.switcherBackground = modeColor(sw, "background")
        cfg.switcherBorder = modeColor(sw, "border")
        cfg.switcherText = modeColor(sw, "text")
        cfg.switcherTextActive = modeColor(sw, "text-active")

        let bg = t["background"] ?? [:]
        cfg.backgroundDark = colorSpec(bg["dark"])
        cfg.backgroundLight = colorSpec(bg["light"])
        cfg.backgroundShader = shaderPath(bg["shader"])
        if let v = bg["shader-fps"], let n = Int(v), (1...120).contains(n) {
            cfg.backgroundShaderFPS = n
        }
        if let v = bg["shader-scale"], let n = Double(v), (0.1...1.0).contains(n) {
            cfg.backgroundShaderScale = CGFloat(n)
        }
        if let v = bg["top-fade"], let n = Double(v), (0.0...256.0).contains(n) {
            cfg.topFade = CGFloat(n)
        }
        if let v = bg["top-fade-exponential"] {
            cfg.topFadeExp = flag(v, cfg.topFadeExp)
        }

        let tb = t["titlebar"] ?? [:]
        cfg.titlebarBackground = modeColor(tb, "background")
        cfg.titlebarText = modeColor(tb, "text")
        cfg.titlebarBorder = modeColor(tb, "border")
        cfg.accent = modeColor(tb, "accent")
        cfg.shadowColor = modeColor(tb, "shadow-color")
        if let f = tb["font"], f.lowercased() != "default" {
            cfg.titlebarFont = f
        }
        if let s = tb["font-size"], let n = Double(s), (6.0...48.0).contains(n) {
            cfg.titlebarFontSize = CGFloat(n)
        }
        if let s = tb["border-width"], let n = Double(s), (0.0...32.0).contains(n) {
            cfg.titlebarBorderWidth = CGFloat(n)
        }
        if let s = tb["shadow-opacity"], let n = Double(s), (0.0...1.0).contains(n) {
            cfg.shadowOpacity = Float(n)
        }
        if let s = tb["shadow-radius"], let n = Double(s), (0.0...64.0).contains(n) {
            cfg.shadowRadius = CGFloat(n)
        }

        let dm = t["doom"] ?? [:]
        if let v = dm["enabled"] {
            cfg.doom.enabled = flag(v, cfg.doom.enabled)
        }
        if let v = dm["toggle"], let b = GCTKeybind(v) {
            cfg.doom.toggle = b
        }
        if let v = dm["animation"],
           let a = DoomAnimation(rawValue: v.lowercased()) {
            cfg.doom.animation = a
        }
        if let s = dm["animation-duration"], let n = Double(s),
           (0.0...1.0).contains(n) {
            cfg.doom.animationDuration = n
        }
        if let v = dm["screen"],
           let s = DoomScreen(rawValue: v.lowercased()) {
            cfg.doom.screen = s
        }
        if let v = dm["start-hidden"] {
            cfg.doom.startHidden = flag(v, cfg.doom.startHidden)
        }
        if let v = dm["launch-at-login"] {
            cfg.doom.launchAtLogin = flag(v, cfg.doom.launchAtLogin)
        }

        var binds = defaultKeybinds
        let kb = t["keybinds"] ?? [:]
        for action in GCTAction.allCases {
            guard let spec = kb[action.rawValue] else { continue }
            if spec.lowercased() == "none" {
                binds[action] = nil
            } else if let bind = GCTKeybind(spec) {
                binds[action] = bind
            }
        }
        cfg.keybinds = binds
        // Remote daemons: every [host.<name>] table with a host key.
        // Sorted by name so colors + menus are deterministic.
        var remotes = [GCTRemoteHost]()
        for (section, vals) in t where section.hasPrefix("host.") {
            let name = String(section.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let h = vals["host"]?.trimmingCharacters(in: .whitespaces),
                  !h.isEmpty else { continue }
            var port = GCTDefaultPort
            if let s = vals["port"], let n = UInt16(s), n > 0 { port = n }
            let token = vals["token"] ?? ""
            let proxy = vals["proxy"]?.trimmingCharacters(in: .whitespaces) ?? ""
            remotes.append(GCTRemoteHost(name: name, host: h, port: port,
                                         token: token, proxy: proxy,
                                         color: modeColor(vals, "color")))
        }
        cfg.remotes = remotes.sorted { $0.name < $1.name }
        return cfg
    }

    // true/false (also yes/no, on/off, 1/0); anything else keeps the
    // default instead of silently reading as false.
    private static func flag(_ raw: String, _ fallback: Bool) -> Bool {
        switch raw.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return fallback
        }
    }

    // `key`, `key-dark`, `key-light` of one table as a GCTModeColor.
    private static func modeColor(_ table: [String: String], _ key: String) -> GCTModeColor {
        GCTModeColor(shared: colorSpec(table[key]),
                     dark: colorSpec(table["\(key)-dark"]),
                     light: colorSpec(table["\(key)-light"]))
    }

    // nil when unset or "default"; "ghostty" and hex pass through.
    private static func colorSpec(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.lowercased() != "default" else { return nil }
        return raw
    }

    // "~/x.glsl" or a path relative to the config dir; "none"/empty = off.
    private static func shaderPath(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.lowercased() != "none" else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return (dir as NSString).appendingPathComponent(expanded)
    }

    static var defaultKeybinds: [GCTAction: GCTKeybind] {
        [
            .newPane: GCTKeybind("cmd+t")!,
            .closePane: GCTKeybind("cmd+w")!,
            .renamePane: GCTKeybind("cmd+r")!,
            .moveFocusAbove: GCTKeybind("cmd+k")!,
            .moveFocusBelow: GCTKeybind("cmd+j")!,
            .moveFocusLeft: GCTKeybind("cmd+h")!,
            .moveFocusRight: GCTKeybind("cmd+l")!,
            .openNewAbove: GCTKeybind("cmd+shift+k")!,
            .openNewBelow: GCTKeybind("cmd+shift+j")!,
            .openNewLeft: GCTKeybind("cmd+shift+h")!,
            .openNewRight: GCTKeybind("cmd+shift+l")!,
            .growAbove: GCTKeybind("cmd+ctrl+k")!,
            .growBelow: GCTKeybind("cmd+ctrl+j")!,
            .growLeft: GCTKeybind("cmd+ctrl+h")!,
            .growRight: GCTKeybind("cmd+ctrl+l")!,
            .shrinkAbove: GCTKeybind("cmd+ctrl+shift+k")!,
            .shrinkBelow: GCTKeybind("cmd+ctrl+shift+j")!,
            .shrinkLeft: GCTKeybind("cmd+ctrl+shift+h")!,
            .shrinkRight: GCTKeybind("cmd+ctrl+shift+l")!,
            // new-window dims reuse move-focus-on-new-window (center) and
            // camera-follows/fits-focus-move (center/fit like focus moves).
            .switcher: GCTKeybind("cmd+p")!,
            .fitAll: GCTKeybind("cmd+0")!,
            .zoomPane: GCTKeybind("cmd+z")!,
            .cameraZoomPane: GCTKeybind("cmd+shift+z")!,
            .copy: GCTKeybind("cmd+c")!,
            .paste: GCTKeybind("cmd+v")!,
            .groupSelection: GCTKeybind("cmd+g")!,
            .ungroup: GCTKeybind("cmd+shift+g")!,
            .toggleFloating: GCTKeybind("cmd+f")!,
            .togglePaneSelection: GCTKeybind("cmd+d")!,
            .clearPaneSelection: GCTKeybind("cmd+shift+d")!,
            .toggleSnapping: GCTKeybind("cmd+shift+s")!,
            .moveWindowToSnap: GCTKeybind("cmd+shift+m")!,
            .reloadConfig: GCTKeybind("cmd+shift+r")!,
            .relaxLayout: GCTKeybind("cmd+shift+a")!,
        ]
    }

    private static let template = """
    # Grand Central Terminal — ~/.config/gct/config.toml
    # Every key is optional; remove a key (or this file) to get defaults.

    # Light/dark mode: "light", "dark", or "system" (follow macOS).
    appearance = "system"

    # Window placement. Panes are kept from overlapping unless you allow
    # it: new panes, moves, and resizes all resolve collisions.
    allow-window-overlap = false
    # Minimum padding between windows in world points (0-256, default 0
    # = flush). Every collision resolve keeps at least this much air.
    # Raising it re-spreads existing panes on reload-config (and next
    # launch); lowering it only affects future moves.
    window-gap = 0
    # Magnetic window snapping (on by default): dragging or resizing a
    # pane within snap-radius pulls it flush with nearby panes and
    # lights full-canvas guide lines (fast fade in/out). Toggling only
    # affects future drags — already-placed panes never jump.
    # Scope: grouped panes (even solo) snap only to siblings in the same
    # group — never outside; whole-group drags snap the group border to
    # ungrouped panes and foreign group borders; ungrouped panes snap to
    # ungrouped panes and group borders (never into grouped members).
    snapping = true
    # Which anchors lock: edges (default), center, or all. Resize always
    # uses the moving edge; this picks the foreign anchors it (and
    # moves) can land on.
    snapping-type = "edges"  # edges | center | all
    # Snap radius in screen points (constant feel at any zoom).
    snap-radius = 16
    # Guide lines: set false to hide them; snap-guide-color tints them
    # (hex like "#ff453a", "default" for translucent silver, "none" to
    # hide — the snap still applies).
    show-snap-guides = true
    snap-guide-color = "default"
    # snap-guide-color-dark / snap-guide-color-light override per mode.
    # "default" = your ghostty foreground, translucent.
    new-window-open-direction = "right"  # above | below | left | right
    # New pane size: "follows" copies the focused pane, or fix a terminal
    # grid as "cols,rows" (e.g. "80,30"). With no panes on the canvas, a
    # standard 80x24 terminal opens. Directional open-new-window-* uses
    # this same size rule.
    new-window-dim = "follows"
    # Keyboard resize step (grow-window-*/shrink-window-*): one terminal
    # cell per press when measurable, else resize-step-points. Cells per
    # press: resize-step-cells = 2 moves two cells.
    resize-step-cells = 1
    resize-step-points = 40
    # Animate the camera to a pane you create here (cmd+t, open-new-window-*,
    # drag-to-create, right-click menu). Panes spawned by gctd/agents or
    # other clients never move the camera. The new pane is always focused.
    move-focus-on-new-window = true
    # Keyboard focus moves (cmd+h/j/k/l, switcher, gctd focus) and new
    # windows: center the newly focused pane, and/or zoom to fit it. Fit
    # implies centered, so the default (both true) zooms to fit; set
    # follows = true, fits = false to only recenter, both false to keep
    # the camera still.
    camera-follows-focus-move = true
    camera-fits-focus-move = true
    # cmd+h/j/k/l remember where you came from: the opposite key goes
    # back to that pane, even when staggered panes make another one
    # nearer. Set false for pure nearest-edge geometry.
    focus-move-memory = true
    # Zoom to fit a pane after you resize it (mouse or keyboard).
    camera-fits-resize = true
    # Picture-in-picture: every camera fit/center (focus moves, fit-all,
    # resize, click) lands panes in the free strip beside the PiP window
    # instead of under it. Checked at fit time; the PiP isn't tracked.
    pip-aware = true
    # cmd+z fullscreen fills the free strip beside the PiP instead of the
    # whole viewport. Needs pip-aware = true.
    pip-aware-zoom = true
    # Unfocused panes fade after dim-delay seconds without output; output
    # wakes them, and panes that are blocked or have a notice never dim.
    # 0 turns it off (max 0.9).
    dim-inactive = 0.35
    dim-delay = 4
    # Desktop notifications from panes you are not looking at: OSC 9/777,
    # the bell, OSC 7501 blocked/done/error, and `gctd notify`. Clicking
    # one focuses the pane.
    notifications = true
    # Cables from a pane to the panes it spawned (gctd open, cmd+t from it).
    # Double-click a cable to tie strands together; drag a tie to slide it,
    # double-click it to remove.
    cables = true
    # Clicking another pane to focus it: "none", "center" (keep zoom) or
    # "fit" (zoom to fit). Runs on release, only for a click, never a drag.
    camera-on-focus-click = "center"
    # Focus the pane under the cursor on mouse motion (same name as
    # ghostty's focus-follows-mouse). Off by default: click to focus.
    focus-follows-mouse = false
    # Scroll (wheel or trackpad) over a terminal scrolls the terminal;
    # scroll over empty canvas pans (two-finger trackpad) or zooms at
    # the cursor (mouse wheel). Set false for the old behavior:
    # trackpad pans, shift+scroll goes to the terminal, wheel zooms.
    scroll-on-terminal-hover = true
    # Canvas zoom limits for wheel/pinch (world scale, 1.0 = actual size):
    # zoom-min 0.005-1, zoom-max 1-8. Above 1.0 the terminal texture is
    # magnified (slightly soft); per-pane cmd-+/- stays razor sharp.
    zoom-min = 0.03
    zoom-max = 4
    # Camera glide in seconds (focus moves, fit-all, switcher jumps),
    # 0.05-10. Slow it down for screen recordings.
    camera-animation-duration = 0.28

    [background]
    # Canvas background per mode. Hex like "#1a1b26" (alpha 1), or with
    # alpha like "#1a1b2680" / "#1234" (alpha < 1 makes the canvas
    # transparent, showing the desktop behind it). "ghostty" reuses
    # the background color from your ghostty config.
    dark = "#000000"
    light = "#ffffff"
    # ShaderToy GLSL (a mainImage using iTime, iResolution, iMouse, ...)
    # drawn as the canvas instead of the color. Path, ~ or relative to
    # this dir. The color's alpha scales the shader's: "#00000080" = half
    # see-through. Unlike shadertoy, the shader's alpha counts: write 1.0.
    # reload-config recompiles an edited shader.
    # shader = "shaders/background.glsl"
    # shader-fps = 60  # 1-120
    # Render resolution vs native (0.1-1). Raymarchers are GPU hogs:
    # 0.5 costs a quarter and looks the same on soft shaders.
    # shader-scale = 1
    # The canvas fades out over this many points at its top edge, so it
    # blends into the menubar instead of ending in a hard line. 0 = off.
    top-fade = 32
    # Exponential falloff: the canvas stays solid until close to the
    # menubar, then decays fast right at its edge. false = even
    # smoothstep ramp.
    top-fade-exponential = true

    [titlebar]
    # Pane titlebar colors. RGBA hex like "#2b2b2b" or "#2b2b2bcc", or
    # "default" for the usual grey. The left/right/bottom border uses the
    # same color as the titlebar background.
    background = "default"
    # Any color in this file also takes "palette:N" (0-15) for your ghostty
    # theme's ANSI color N, e.g. accent = "palette:5" (magenta).
    # Every color below also takes -dark / -light variants that win over
    # the plain key in their mode, e.g. background-dark = "#2b2b2b" /
    # background-light = "#d8d8d8".
    # "ghostty" (background, any variant) derives it from your ghostty
    # theme: window-titlebar-background if set, else the background
    # nudged toward the foreground; text follows unless set here.
    background-dark = "default"
    background-light = "default"
    text = "default"
    text-dark = "default"
    text-light = "default"
    # Side/bottom border fill ("default" = the titlebar background).
    border = "default"
    # Selected / zoomed pane chrome ("default" = your ghostty theme's blue).
    accent = "default"
    # Drop shadow color ("default" = black).
    shadow-color = "default"
    # Title text font: family name (e.g. "SF Mono") and size in points.
    font = "default"
    font-size = 12
    # Border on the left/right/bottom edges in points (the top edge is the
    # titlebar itself). Wider borders grab edges/corners for resizing more
    # easily, even zoomed out.
    border-width = 4
    # Drop shadow: opacity 0 turns it off, radius blurs it. Defaults match
    # the current look.
    shadow-opacity = 0.55
    shadow-radius = 12

    [statusbar]
    # Overlay bar of xbar-compatible plugin components: executables in
    # ~/.config/gct/statusbar/ named {name}.{interval}.{ext} (e.g.
    # clock.10s.sh). New plugins are picked up live — no recompile, no
    # restart. Flip `enabled` (or any key here) then reload-config.
    enabled = false
    # Bar edge: "top" or "bottom". Always above panes on its own layer;
    # panes slide under it, never collide with it.
    position = "bottom"
    # Ordered cells: plugin basenames (clock matches clock.10s.sh) plus
    # `gap` spacers that absorb leftover width, so
    # component-gap-component-gap-component aligns left/center/right.
    components = "clock, gap"
    # Bar height (16-64pt) and spacing between cells.
    height = 26
    spacing = 8
    # Colors: RGBA hex like "#1a1b26" or "#1a1b2680", or "default" for
    # the usual greys.
    # background-dark / -light and text-dark / -light override per mode.
    background = "default"
    text = "default"
    # Font: family name (e.g. "SF Mono") and size in points.
    font = "default"
    font-size = 12

    [switcher]
    # Pane switcher overlay colors, same hex / -dark / -light rules.
    # "default" = the usual dark panel.
    background = "default"
    border = "default"
    text = "default"
    # Text of the most recently focused pane's row.
    text-active = "default"
    # Overall opacity 0-1 (multiplies the background alpha).
    opacity = 1

    [doom]
    # Global-hotkey dropdown: the fullscreen canvas fades in (or slides
    # down from the top) on `toggle`; the same hotkey hides it again.
    # On by default — GCT sits hidden until summoned. `toggle` re-arms
    # live via reload-config; enabled/start-hidden/launch-at-login need
    # a relaunch.
    enabled = true
    # System-wide hotkey (Carbon, no Accessibility permission needed).
    # Named keys work here: space, tab, return, enter, escape, delete,
    # f1-f12, e.g. toggle = "ctrl+f12". WARNING: the combo is eaten
    # system-wide while GCT runs (shells can't see it), and stock macOS
    # binds ctrl+space to input-source switching — free it in Settings
    # or pick another bind.
    toggle = "ctrl+space"
    # Show/hide animation: "fade" (default) or "slide" (down from the top).
    animation = "fade"  # fade | slide
    # Animation length in seconds (0-1).
    animation-duration = 0.2
    # Which screen to summon the fullscreen canvas on: mouse (the screen
    # under the cursor), main, or menubar (the screen holding the menubar).
    screen = "mouse"  # mouse | main | menubar
    # Launch ordered-out (hotkey summons); false = visible on launch.
    start-hidden = true
    # Register as a login item (also visible in system Settings).
    launch-at-login = false

    [keybinds]
    # App shortcuts. Modifiers cmd, ctrl, alt, shift joined with "+"; the
    # last part is the key, e.g. new-pane = "cmd+shift+t". Arrow keys
    # (left/right/up/down) and f1-f12 work too. Set any bind to "none"
    # to unbind it; removing a key restores its default.
    new-pane = "cmd+t"
    close-pane = "cmd+w"
    rename-pane = "cmd+r"
    move-focus-above = "cmd+k"
    move-focus-below = "cmd+j"
    move-focus-left = "cmd+h"
    move-focus-right = "cmd+l"
    # Directional new panes. Side is fixed by the action; size follows
    # new-window-dim; focus/camera follow move-focus-on-new-window and
    # the camera-follows/fits-focus-move flags.
    open-new-window-above = "cmd+shift+k"
    open-new-window-below = "cmd+shift+j"
    open-new-window-left = "cmd+shift+h"
    open-new-window-right = "cmd+shift+l"
    # Directional resize: grow moves that edge outward, shrink pulls it
    # back. Opposite edge stays put; with overlap disallowed, growing
    # shoves blocking panes (and chains) out of the way along that axis.
    grow-window-above = "cmd+ctrl+k"
    grow-window-below = "cmd+ctrl+j"
    grow-window-left = "cmd+ctrl+h"
    grow-window-right = "cmd+ctrl+l"
    shrink-window-above = "cmd+ctrl+shift+k"
    shrink-window-below = "cmd+ctrl+shift+j"
    shrink-window-left = "cmd+ctrl+shift+h"
    shrink-window-right = "cmd+ctrl+shift+l"
    switcher = "cmd+p"
    fit-all = "cmd+0"
    # Focus zoom: the pane fills the viewport sharp (surface reflows +
    # re-renders, never a raster upscale). Toggle restores frame + camera.
    zoom-pane = "cmd+z"
    # Camera zoom: scale the canvas so the focused pane fills the view
    # (camera only; the pane keeps its size, so the raster is magnified up
    # to zoom-max). fit-all or any camera move gets you back.
    camera-zoom-pane = "cmd+shift+z"
    copy = "cmd+c"
    paste = "cmd+v"
    # Terminal groups: right-drag empty space rubber-bands panes into a
    # group (colored background, blocks non-members even when overlap is
    # allowed); right-click the background for rename/color/ungroup.
    group-selection = "cmd+g"
    ungroup = "cmd+shift+g"
    # Multi-select: right-drag stages a selection WITHOUT grouping
    # (right-click acts on it: group / close / clear). Shift+click a
    # titlebar toggles that pane; move any selected titlebar to drag
    # the whole selection; close-pane closes every selected pane.
    toggle-pane-selection = "cmd+d"
    clear-pane-selection = "cmd+shift+d"
    # Floating: the focused pane floats above same-scope windows (ignores
    # the overlap rule; foreign group bounds still block). With overlap
    # allowed every window already overlaps, so toggling only changes the
    # stacking + marker. Re-press re-tiles into the layout.
    toggle-floating = "cmd+f"
    # Snapping: flip magnetic window snapping at runtime (session-only;
    # never moves already-placed panes). Default bind below; rebind or
    # set "none" to unbind.
    toggle-snapping = "cmd+shift+s"
    # Snap the focused window to its nearest snap target, even when
    # snapping is off. Rebind, or set "none" to unbind.
    move-window-to-snap = "cmd+shift+m"
    # Config: re-read config.toml and apply live (theme, keybinds,
    # snapping/overlap policy, doom hotkey). Doom structural keys
    # (enabled, start-hidden, launch-at-login) need a relaunch.
    reload-config = "cmd+shift+r"

    # Remote daemons: one [host.<name>] table per daemon host.
    # name = canvas label + window color key; host = TCP address
    # (ssh-tunnel endpoint works); port defaults to 7420; token must
    # match the daemon's --token/GCT_TOKEN; color tints that host's
    # windows (hex like "#f59e0b", "default" = auto from the palette;
    # color-dark / color-light override per mode).
    # Right-click empty canvas for "New remote pane" per host.
    # Reload-config reconnects when these change.
    # proxy = ssh jump host (user@bastion or an ~/.ssh/config alias); the
    # canvas runs `ssh -W host:port proxy`, key auth only (no prompts).
    # [host.enterprise]
    # host = "127.0.0.1"
    # port = 17421
    # token = "s3cret"
    # proxy = "me@bastion.example.com"
    # color = "#f59e0b"
    """
}

// One remote daemon host from config.
struct GCTRemoteHost: Equatable {
    var name: String       // [host.<name>] label (also the fallback color key)
    var host: String       // TCP address (hostname/IP, ssh-tunnel endpoint ok)
    var port: UInt16 = GCTDefaultPort
    var token: String = ""
    var proxy: String = "" // ssh jump host ("user@bastion" or ~/.ssh/config alias); "" = direct
    var color = GCTModeColor() // hex like "#f59e0b"; unset = auto from palette
}
 // MARK: - Appearance + resolved theme

enum GCTAppearance: String {
    case light, dark, system
}

// Chrome resolved for the current light/dark mode. Refreshed on launch and
// appearance changes; read by main (window background) and PaneView.
struct GCTTheme {
    static var current = GCTTheme(dark: true)

    let canvasBackground: NSColor
    let titlebarBackgroundFocused: NSColor
    let titlebarBackgroundUnfocused: NSColor
    let titlebarTextFocused: NSColor
    let titlebarTextUnfocused: NSColor
    let borderFocused: NSColor
    let borderUnfocused: NSColor
    let accent: NSColor
    // nil = guides off ("none").
    let snapGuide: NSColor?
    // ghostty's 16 ANSI colors (empty without ghostty), and the chromatic
    // subset hosts hash onto.
    let ansi: [NSColor]
    let hostPalette: [NSColor]
    let shadowColor: NSColor
    let switcherBackground: NSColor
    let switcherBorder: NSColor
    let switcherText: NSColor
    let switcherTextActive: NSColor
    // Left/right/bottom border width in points (top edge is the titlebar
    // itself). Drop shadow; opacity 0 turns it off.
    let borderWidth: CGFloat
    let shadowOpacity: Float
    let shadowRadius: CGFloat
    let titleFont: NSFont
    let statusbarBackground: NSColor
    let statusbarText: NSColor
    let statusbarFont: NSFont

    // Effective light/dark honoring the config's appearance setting.
    static func isDark() -> Bool {
        switch GCTConfig.current.appearance {
        case .light: return false
        case .dark: return true
        case .system:
            return NSApp.effectiveAppearance.bestMatch(
                from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    // Recompute from config + ghostty's resolved colors into `current`.
    static func refresh(ghostty: GhosttyColors) {
        current = GCTTheme(dark: isDark(), ghostty: ghostty)
    }

    init(dark: Bool, ghostty: GhosttyColors = GhosttyColors()) {
        let cfg = GCTConfig.current
        func pick(_ m: GCTModeColor) -> NSColor? {
            Self.color(m.spec(dark: dark), ghostty: nil, palette: ghostty.palette)
        }

        // Canvas background.
        let bgSpec = dark ? cfg.backgroundDark : cfg.backgroundLight
        if let c = Self.color(bgSpec, ghostty: ghostty.background, palette: ghostty.palette) {
            canvasBackground = c
        } else {
            canvasBackground = dark ? .black : .white
        }

        // Titlebar background: one explicit color for both states (this
        // mode's color), or the usual greys
        // (focused slightly more salient than unfocused).
        let tbSpec = cfg.titlebarBackground.spec(dark: dark)
        let tbGhostty = tbSpec?.lowercased() == Self.ghosttySpec
            ? Self.ghosttyTitlebar(ghostty) : nil
        if let tbGhostty {
            titlebarBackgroundFocused = tbGhostty.backgroundFocused
            titlebarBackgroundUnfocused = tbGhostty.backgroundUnfocused
        } else if let c = Self.color(tbSpec, ghostty: nil, palette: ghostty.palette) {
            titlebarBackgroundFocused = c
            titlebarBackgroundUnfocused = c
        } else if dark {
            titlebarBackgroundFocused = NSColor(white: 0.26, alpha: 1)
            titlebarBackgroundUnfocused = NSColor(white: 0.23, alpha: 1)
        } else {
            titlebarBackgroundFocused = NSColor(white: 0.80, alpha: 1)
            titlebarBackgroundUnfocused = NSColor(white: 0.86, alpha: 1)
        }

        // Titlebar text: explicit color, else the theme's (with a "ghostty"
        // titlebar), else contrast with the background.
        if let c = pick(cfg.titlebarText) {
            titlebarTextFocused = c
            titlebarTextUnfocused = c
        } else if let tbGhostty {
            titlebarTextFocused = tbGhostty.textFocused
            titlebarTextUnfocused = tbGhostty.textUnfocused
        } else if titlebarBackgroundFocused.gctLuminance > 0.55 {
            titlebarTextFocused = NSColor(white: 0.12, alpha: 1)
            titlebarTextUnfocused = NSColor(white: 0.38, alpha: 1)
        } else {
            titlebarTextFocused = NSColor(white: 0.92, alpha: 1)
            titlebarTextUnfocused = NSColor(white: 0.70, alpha: 1)
        }

        // Side/bottom borders: same color as the titlebar background (unless
        // set), so the chrome reads as one frame around the terminal.
        if let c = pick(cfg.titlebarBorder) {
            borderFocused = c
            borderUnfocused = c
        } else {
            borderFocused = titlebarBackgroundFocused
            borderUnfocused = titlebarBackgroundUnfocused
        }
        // Accent defaults to the ghostty theme's blue; guides to its
        // foreground, translucent (silver when ghostty gave nothing).
        let ansiBlue = ghostty.palette.indices.contains(Self.ansiBlue)
            ? ghostty.palette[Self.ansiBlue] : nil
        accent = pick(cfg.accent) ?? ansiBlue ?? .systemBlue
        if cfg.snapGuideColor.spec(dark: dark)?.lowercased() == Self.noneSpec {
            snapGuide = nil
        } else if let c = pick(cfg.snapGuideColor) {
            snapGuide = c
        } else {
            snapGuide = (ghostty.foreground ?? NSColor(white: 0.75, alpha: 1))
                .withAlphaComponent(Self.guideAlpha)
        }
        ansi = ghostty.palette
        hostPalette = Self.hostAnsi.compactMap {
            ghostty.palette.indices.contains($0) ? ghostty.palette[$0] : nil
        }
        shadowColor = pick(cfg.shadowColor) ?? .black
        borderWidth = max(0, min(32, cfg.titlebarBorderWidth))
        shadowOpacity = max(0, min(1, cfg.shadowOpacity))
        shadowRadius = max(0, min(64, cfg.shadowRadius))

        let size = cfg.titlebarFontSize
        if let name = cfg.titlebarFont, let f = NSFont(name: name, size: size) {
            titleFont = f
        } else {
            titleFont = .monospacedSystemFont(ofSize: size, weight: .medium)
        }
        // Status bar: explicit colors or the usual dark/light greys.
        // Opacity stays in the view (it multiplies background alpha).
        if let c = pick(cfg.statusbarBackground) {
            statusbarBackground = c
        } else if dark {
            statusbarBackground = NSColor(white: 0.13, alpha: 1)
        } else {
            statusbarBackground = NSColor(white: 0.93, alpha: 1)
        }
        if let c = pick(cfg.statusbarText) {
            statusbarText = c
        } else if statusbarBackground.gctLuminance > 0.55 {
            statusbarText = NSColor(white: 0.12, alpha: 1)
        } else {
            statusbarText = NSColor(white: 0.92, alpha: 1)
        }

        // Switcher: dark panel by default in both modes (it floats over
        // the canvas like a HUD); override per mode to go light.
        switcherBackground = pick(cfg.switcherBackground)
            ?? NSColor(white: 0.07, alpha: 0.97)
        switcherBorder = pick(cfg.switcherBorder)
            ?? NSColor(white: 0.25, alpha: 1)
        switcherText = pick(cfg.switcherText)
            ?? NSColor(white: 0.75, alpha: 1)
        switcherTextActive = pick(cfg.switcherTextActive)
            ?? .white

        let sbSize = cfg.statusbarFontSize
        if let name = cfg.statusbarFont, let f = NSFont(name: name, size: sbSize) {
            statusbarFont = f
        } else {
            statusbarFont = .monospacedSystemFont(ofSize: sbSize, weight: .regular)
        }
    }

    // Hex, "ghostty" (the caller's ghostty color), or "palette:N" (ghostty
    // ANSI N, 0-15, e.g. "palette:5" = magenta).
    private static func color(_ spec: String?, ghostty: NSColor?,
                              palette: [NSColor]) -> NSColor? {
        guard let spec else { return nil }
        let lower = spec.lowercased()
        if lower == ghosttySpec { return ghostty }
        if lower.hasPrefix(paletteSpec) {
            guard let i = Int(lower.dropFirst(paletteSpec.count)),
                  palette.indices.contains(i) else { return nil }
            return palette[i]
        }
        return NSColor(gctHex: spec)
    }

    private static let ghosttySpec = "ghostty"
    private static let paletteSpec = "palette:"
    private static let noneSpec = "none"
    private static let ansiBlue = 4
    private static let guideAlpha: CGFloat = 0.55
    // ANSI red..cyan + bright red..cyan: skips black/white/greys.
    private static let hostAnsi = Array(1...6) + Array(9...14)
    // "ghostty" titlebar mixes: background toward foreground (focused a
    // touch more salient), unfocused text faded toward the titlebar.
    private static let focusedMix: CGFloat = 0.12
    private static let unfocusedMix: CGFloat = 0.07
    private static let unfocusedTextFade: CGFloat = 0.35

    private struct TitlebarColors {
        let backgroundFocused: NSColor
        let backgroundUnfocused: NSColor
        let textFocused: NSColor
        let textUnfocused: NSColor
    }

    // The theme's window-titlebar-* keys win; else its background blended
    // toward its foreground: lighter on dark themes, darker on light ones,
    // tint kept. e.g. #121212 bg + #dedede fg -> #2a2a2a. Nil without a
    // ghostty background (greys then).
    private static func ghosttyTitlebar(_ g: GhosttyColors) -> TitlebarColors? {
        guard let bg = g.background else { return nil }
        let fg = g.titlebarForeground ?? g.foreground ?? .white

        let focused: NSColor
        let unfocused: NSColor
        if let tb = g.titlebarBackground {
            focused = tb
            unfocused = tb
        } else {
            focused = bg.blended(withFraction: focusedMix, of: fg) ?? bg
            unfocused = bg.blended(withFraction: unfocusedMix, of: fg) ?? bg
        }

        let faded = fg.blended(withFraction: unfocusedTextFade, of: unfocused) ?? fg
        return TitlebarColors(backgroundFocused: focused, backgroundUnfocused: unfocused,
                              textFocused: fg, textUnfocused: faded)
    }
}