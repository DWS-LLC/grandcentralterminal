// ~/.config/gct/config.toml: appearance + keybind configuration.
//
// Created with defaults on first launch. Unknown keys are ignored so older
// builds keep working against newer configs; malformed values fall back to
// their defaults. Parsed once at launch — changes need a relaunch.

import AppKit

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

    // Rec. 601 luminance in 0...1, sRGB components.
    var gctLuminance: Double {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.299 * Double(c.redComponent)
            + 0.587 * Double(c.greenComponent)
            + 0.114 * Double(c.blueComponent)
    }
}

// MARK: - Keybinds

// App shortcuts ("cmd+t", "ctrl+shift+k", "a"). Character-based: the last
// + separated part is the key, everything before it is modifiers.
struct GCTKeybind {
    let mods: NSEvent.ModifierFlags
    let key: String

    init?(_ spec: String) {
        var mods: NSEvent.ModifierFlags = []
        var parts = spec.lowercased().split(separator: "+").map(String.init)
        guard !parts.isEmpty else { return nil }
        let key = parts.removeLast()
        guard key.count == 1, !key.isEmpty else { return nil }
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
        self.key = key
    }

    // Exact modifier-set match, so cmd+k doesn't fire on cmd+shift+k.
    func matches(_ event: NSEvent) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(relevant) == mods.intersection(relevant),
              let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return chars == key
    }
}

// Which side of the focused pane cmd+t opens on.
enum GCTNewWindowDirection: String {
    case above, below, left, right
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
    case switcher = "switcher"
    case fitAll = "fit-all"
    case copy = "copy"
    case paste = "paste"
}

// MARK: - Config

struct GCTConfig {
    static var current = GCTConfig()

    var appearance: GCTAppearance = .system
    // Color specs: nil = mode default, "ghostty" = ghostty's background, else hex.
    var backgroundDark: String?
    var backgroundLight: String?
    var titlebarBackground: String?
    var titlebarText: String?
    var titlebarFont: String?
    var titlebarFontSize: CGFloat = 12
    var keybinds: [GCTAction: GCTKeybind] = GCTConfig.defaultKeybinds
    // Panes are kept from overlapping: creation, moves, and resizes all
    // resolve collisions.
    var allowWindowOverlap = false
    // Which side of the focused pane cmd+t opens on.
    var newWindowDirection = GCTNewWindowDirection.right
    // Size of new panes: focused pane's size, or a fixed cols x rows grid
    // (80x24 when the canvas is empty).
    var newWindowDim = GCTNewWindowDim.follows
    // Animate the camera to center a pane created with cmd+t.
    var moveFocusOnNewWindow = true
    // Directional focus moves (cmd+h/j/k/l): center the newly focused
    // pane, and/or zoom to fit it. Independent; both default true (fit
    // implies centered, so both true just zooms to fit).
    var cameraFollowsFocusMove = true
    var cameraFitsFocusMove = true

    static let path: String = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".config/gct/config.toml")

    // Read the config file, creating it with defaults if missing.
    static func load() -> GCTConfig {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return parse(text)
        }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            atPath: dir.path, withIntermediateDirectories: true)
        try? template.data(using: .utf8)?.write(to: url)
        return parse(template)
    }

    private static func parse(_ text: String) -> GCTConfig {
        var cfg = GCTConfig()
        let t = TOML.parse(text)
        let root = t[""] ?? [:]

        if let a = root["appearance"], let mode = GCTAppearance(rawValue: a.lowercased()) {
            cfg.appearance = mode
        }

        if let v = root["allow-window-overlap"] {
            cfg.allowWindowOverlap = v.lowercased() == "true"
        }
        if let v = root["new-window-open-direction"],
           let d = GCTNewWindowDirection(rawValue: v.lowercased()) {
            cfg.newWindowDirection = d
        }
        if let v = root["new-window-dim"] {
            cfg.newWindowDim = GCTNewWindowDim.parse(v)
        }
        if let v = root["move-focus-on-new-window"] {
            cfg.moveFocusOnNewWindow = v.lowercased() == "true"
        }
        if let v = root["camera-follows-focus-move"] {
            cfg.cameraFollowsFocusMove = v.lowercased() == "true"
        }
        if let v = root["camera-fits-focus-move"] {
            cfg.cameraFitsFocusMove = v.lowercased() == "true"
        }

        let bg = t["background"] ?? [:]
        cfg.backgroundDark = colorSpec(bg["dark"])
        cfg.backgroundLight = colorSpec(bg["light"])

        let tb = t["titlebar"] ?? [:]
        cfg.titlebarBackground = colorSpec(tb["background"])
        cfg.titlebarText = colorSpec(tb["text"])
        if let f = tb["font"], f.lowercased() != "default" {
            cfg.titlebarFont = f
        }
        if let s = tb["font-size"], let n = Double(s), (6.0...48.0).contains(n) {
            cfg.titlebarFontSize = CGFloat(n)
        }

        var binds = defaultKeybinds
        let kb = t["keybinds"] ?? [:]
        for action in GCTAction.allCases {
            if let spec = kb[action.rawValue], let bind = GCTKeybind(spec) {
                binds[action] = bind
            }
        }
        cfg.keybinds = binds
        return cfg
    }

    // nil when unset or "default"; "ghostty" and hex pass through.
    private static func colorSpec(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.lowercased() != "default" else { return nil }
        return raw
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
            // new-window dims reuse move-focus-on-new-window (center) and
            // camera-follows/fits-focus-move (center/fit like focus moves).
            .switcher: GCTKeybind("cmd+p")!,
            .fitAll: GCTKeybind("cmd+0")!,
            .copy: GCTKeybind("cmd+c")!,
            .paste: GCTKeybind("cmd+v")!,
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
    # Side of the focused pane that cmd+t opens on.
    new-window-open-direction = "right"  # above | below | left | right
    # New pane size: "follows" copies the focused pane, or fix a terminal
    # grid as "cols,rows" (e.g. "80,30"). With no panes on the canvas, a
    # standard 80x24 terminal opens. Directional open-new-window-* uses
    # this same size rule.
    new-window-dim = "follows"
    # Animate the camera to center a pane created with cmd+t or an
    # open-new-window-* bind (when its focus move fires).
    move-focus-on-new-window = true
    # Directional focus moves (cmd+h/j/k/l): center the newly focused
    # pane, and/or zoom to fit it. Independent; both default true (fit
    # implies centered, so both true just zooms to fit).
    camera-follows-focus-move = true
    camera-fits-focus-move = true

    [background]
    # Canvas background per mode. Hex like "#1a1b26" (alpha 1), or with
    # alpha like "#1a1b2680" / "#1234" (alpha < 1 makes the canvas
    # transparent, showing the desktop behind it). "ghostty" reuses
    # the background color from your ghostty config.
    dark = "#000000"
    light = "#ffffff"

    [titlebar]
    # Pane titlebar colors. Hex like "#2b2b2b", or "default" for the usual grey.
    background = "default"
    text = "default"
    # Title text font: family name (e.g. "SF Mono") and size in points.
    font = "default"
    font-size = 12

    [keybinds]
    # App shortcuts. Modifiers cmd, ctrl, alt, shift joined with "+"; the
    # last part is the key, e.g. new-pane = "cmd+shift+t".
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
    switcher = "cmd+p"
    fit-all = "cmd+0"
    copy = "cmd+c"
    paste = "cmd+v"
    """
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
    let titleFont: NSFont

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

    // Recompute from config + ghostty's resolved background into `current`.
    static func refresh(ghosttyBackground: NSColor?) {
        current = GCTTheme(dark: isDark(), ghosttyBackground: ghosttyBackground)
    }

    init(dark: Bool, ghosttyBackground: NSColor? = nil) {
        let cfg = GCTConfig.current

        // Canvas background.
        let bgSpec = dark ? cfg.backgroundDark : cfg.backgroundLight
        if let c = Self.color(bgSpec, ghostty: ghosttyBackground) {
            canvasBackground = c
        } else {
            canvasBackground = dark ? .black : .white
        }

        // Titlebar background: one explicit color for both states, or the
        // usual greys (focused slightly more salient than unfocused).
        if let c = Self.color(cfg.titlebarBackground, ghostty: nil) {
            titlebarBackgroundFocused = c
            titlebarBackgroundUnfocused = c
        } else if dark {
            titlebarBackgroundFocused = NSColor(white: 0.26, alpha: 1)
            titlebarBackgroundUnfocused = NSColor(white: 0.23, alpha: 1)
        } else {
            titlebarBackgroundFocused = NSColor(white: 0.80, alpha: 1)
            titlebarBackgroundUnfocused = NSColor(white: 0.86, alpha: 1)
        }

        // Titlebar text: explicit color, else contrast with the background.
        if let c = Self.color(cfg.titlebarText, ghostty: nil) {
            titlebarTextFocused = c
            titlebarTextUnfocused = c
        } else if titlebarBackgroundFocused.gctLuminance > 0.55 {
            titlebarTextFocused = NSColor(white: 0.12, alpha: 1)
            titlebarTextUnfocused = NSColor(white: 0.38, alpha: 1)
        } else {
            titlebarTextFocused = NSColor(white: 0.92, alpha: 1)
            titlebarTextUnfocused = NSColor(white: 0.70, alpha: 1)
        }

        // Pane borders: focused more salient.
        if dark {
            borderFocused = NSColor(white: 0.28, alpha: 1)
            borderUnfocused = NSColor(white: 0.19, alpha: 1)
        } else {
            borderFocused = NSColor(white: 0.55, alpha: 1)
            borderUnfocused = NSColor(white: 0.78, alpha: 1)
        }

        let size = cfg.titlebarFontSize
        if let name = cfg.titlebarFont, let f = NSFont(name: name, size: size) {
            titleFont = f
        } else {
            titleFont = .monospacedSystemFont(ofSize: size, weight: .medium)
        }
    }

    private static func color(_ spec: String?, ghostty: NSColor?) -> NSColor? {
        guard let spec else { return nil }
        if spec.lowercased() == "ghostty" { return ghostty }
        return NSColor(gctHex: spec)
    }
}