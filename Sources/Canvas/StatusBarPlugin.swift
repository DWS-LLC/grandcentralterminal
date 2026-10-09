// GCT status bar components: xbar/BitBar-compatible executable plugins.
//
// A component is any executable dropped into ~/.config/gct/statusbar/ —
// any language, no recompile, no restart (the bar rescans the folder).
// Filename sets the refresh cadence: {name}.{interval}.{ext}, e.g.
// `clock.10s.sh` (10s, 1m, 2h, 1d). No interval = run once, then only
// on manual refresh.
//
// Plugin protocol (xbar subset, https://xbarapp.com/docs/):
// - stdout lines before the first `---` cycle in the bar (header).
// - lines after `---` build the click menu; `--` prefixes nest submenus
//   (`----` = level 2, two dashes per level).
// - `title | key=value ...` params: color, font, size, length, image,
//   templateImage (base64), href, shell + param1..9, terminal, refresh,
//   disabled, dropdown, trim, alternate.
// - a bare `---` inside the menu section renders a menu separator.
//
// This file is dependency-free (Foundation + AppKit only) so the parser
// can be smoke-tested standalone with swiftc.

import AppKit

// MARK: - Filename interval + token matching

enum StatusBarInterval {
    /// `(name, seconds)` from `{name}.{interval}.{ext}`.
    /// nil seconds = run once, then only on manual refresh.
    static func parse(filename: String) -> (name: String, seconds: TimeInterval?) {
        let parts = filename.split(separator: ".")
        guard parts.count >= 3 else { return (filename, nil) }
        let raw = String(parts[parts.count - 2]).lowercased()
        var num = ""
        var unit: Character?
        for c in raw {
            if c.isNumber { num.append(c) } else if unit == nil { unit = c } else { return (filename, nil) }
        }
        guard let n = Double(num), let u = unit else { return (filename, nil) }
        let mult: Double
        switch u {
        case "s": mult = 1
        case "m": mult = 60
        case "h": mult = 3600
        case "d": mult = 86400
        default: return (filename, nil)
        }
        let name = parts.dropLast(2).joined(separator: ".")
        return (name.isEmpty ? filename : name, max(1, n * mult))
    }
}

enum StatusBarCatalog {
    /// "gap" (also "flex" / "|") is an expanding spacer, not a plugin.
    static func isGap(_ token: String) -> Bool {
        let t = token.lowercased()
        return t == "gap" || t == "flex" || t == "<gap>" || token == "|"
    }

    /// Token matches an exact filename first, then the basename before
    /// the interval (`clock` -> `clock.10s.sh`).
    static func match(token: String, files: [URL]) -> URL? {
        if let exact = files.first(where: { $0.lastPathComponent == token }) { return exact }
        let lower = token.lowercased()
        return files.first(where: {
            StatusBarInterval.parse(filename: $0.lastPathComponent).name.lowercased() == lower
        })
    }
}

// MARK: - Params

struct StatusBarParams {
    var color: NSColor?
    var fontName: String?
    var fontSize: CGFloat?
    var length: Int?
    var trim = true
    var disabled = false
    var dropdown = true
    var alternate = false
    var href: String?
    var shell: String?
    var shellArgs: [String] = []
    var terminal = false
    var refresh = false
    var image: NSImage?
    var templateImage: NSImage?

    var isActionable: Bool { href != nil || shell != nil || refresh }

    static func parse(_ raw: String) -> StatusBarParams {
        var p = StatusBarParams()
        for (k, v) in splitParams(raw) {
            switch k {
            case "color": p.color = StatusBarColors.parse(v)
            case "font": p.fontName = v
            case "size": if let n = Double(v) { p.fontSize = CGFloat(n) }
            case "length": if let n = Int(v), n > 0 { p.length = n }
            case "trim": p.trim = v.lowercased() != "false"
            case "disabled": p.disabled = v.lowercased() == "true"
            case "dropdown": p.dropdown = v.lowercased() != "false"
            case "alternate": p.alternate = v.lowercased() == "true"
            case "href": p.href = v
            case "shell", "bash": p.shell = v
            case "terminal": p.terminal = v.lowercased() == "true"
            case "refresh": p.refresh = v.lowercased() == "true"
            case "image": p.image = StatusBarImage.decode(v, template: false)
            case "templateimage": p.templateImage = StatusBarImage.decode(v, template: true)
            default:
                if k.hasPrefix("param"), let i = Int(k.dropFirst(5)), (1...9).contains(i) {
                    while p.shellArgs.count < i { p.shellArgs.append("") }
                    p.shellArgs[i - 1] = v
                }
            }
        }
        return p
    }

    /// Split `k=v k="quoted v" ...` on whitespace outside quotes.
    /// Backslash escapes (`Activity\ Monitor`) collapse to the literal
    /// char — xbar plugins use them for spaces in param values.
    private static func splitParams(_ s: String) -> [(String, String)] {
        var out = [(String, String)]()
        var cur = ""
        var quote: Character?
        var escaped = false
        func flush() {
            let t = cur.trimmingCharacters(in: .whitespaces)
            cur = ""
            guard !t.isEmpty, let eq = t.firstIndex(of: "=") else { return }
            let k = String(t[..<eq]).lowercased()
            var v = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.count >= 2,
               (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            out.append((k, v))
        }
        for c in s {
            if escaped {
                cur.append(c)
                escaped = false
            } else if c == "\\", quote == nil {
                escaped = true
            } else if let q = quote {
                cur.append(c)
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
                cur.append(c)
            } else if c.isWhitespace {
                flush()
            } else {
                cur.append(c)
            }
        }
        if escaped { cur.append("\\") }
        flush()
        return out
    }
}

// MARK: - Lines + output

struct StatusBarLine {
    var title: String
    var params: StatusBarParams
    var submenuLevel = 0
    var isSeparator = false

    static func parse(_ raw: String) -> StatusBarLine {
        // Bare `---` is a separator, not a submenu marker: check before
        // stripping `--` prefixes (`---` would read as level 1 + "-").
        if raw.trimmingCharacters(in: .whitespaces) == "---" {
            return StatusBarLine(title: "", params: StatusBarParams(), isSeparator: true)
        }
        var s = raw
        var level = 0
        while s.hasPrefix("--") { level += 1; s = String(s.dropFirst(2)) }
        if s.hasPrefix(" ") { s = String(s.dropFirst()) }
        if let pipe = s.firstIndex(of: "|") {
            let params = StatusBarParams.parse(String(s[s.index(after: pipe)...]))
            var title = String(s[..<pipe])
            if params.trim { title = title.trimmingCharacters(in: .whitespaces) }
            return StatusBarLine(title: title, params: params, submenuLevel: level)
        }
        // `-- ---`: separator nested under a submenu.
        if s.trimmingCharacters(in: .whitespaces) == "---" {
            return StatusBarLine(title: "", params: StatusBarParams(),
                                 submenuLevel: level, isSeparator: true)
        }
        return StatusBarLine(title: s.trimmingCharacters(in: .whitespaces),
                             params: StatusBarParams(), submenuLevel: level)
    }
}

struct StatusBarOutput {
    var header: [StatusBarLine]  // cycles in the bar
    var menu: [StatusBarLine]    // click menu (empty = header doubles as menu)

    static let empty = StatusBarOutput(header: [], menu: [])

    static func parse(_ text: String) -> StatusBarOutput {
        var header = [StatusBarLine]()
        var menu = [StatusBarLine]()
        var pastDivider = false
        for raw in text.components(separatedBy: "\n") {
            // First bare `---` divides header from menu; later ones are
            // menu separators.
            if !pastDivider, raw.trimmingCharacters(in: .whitespaces) == "---" {
                pastDivider = true
                continue
            }
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let line = StatusBarLine.parse(raw)
            if pastDivider { menu.append(line) } else { header.append(line) }
        }
        return StatusBarOutput(header: header, menu: menu)
    }
}

// MARK: - Colors + images

enum StatusBarColors {
    /// Named colors (xbar style) or #rgb/#rrggbb/#rrggbbaa hex.
    static func parse(_ v: String) -> NSColor? {
        let s = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch s {
        case "black": return .black
        case "white": return .white
        case "red": return .systemRed
        case "green": return .systemGreen
        case "blue": return .systemBlue
        case "yellow": return .systemYellow
        case "orange": return .systemOrange
        case "purple": return .systemPurple
        case "gray", "grey": return .systemGray
        default: break
        }
        var hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let n = UInt32(hex, radix: 16) else { return nil }
        if hex.count == 6 {
            return NSColor(red: CGFloat((n >> 16) & 0xFF) / 255,
                           green: CGFloat((n >> 8) & 0xFF) / 255,
                           blue: CGFloat(n & 0xFF) / 255, alpha: 1)
        }
        return NSColor(red: CGFloat((n >> 24) & 0xFF) / 255,
                       green: CGFloat((n >> 16) & 0xFF) / 255,
                       blue: CGFloat((n >> 8) & 0xFF) / 255,
                       alpha: CGFloat(n & 0xFF) / 255)
    }
}

enum StatusBarImage {
    /// Base64 blob (any NSImage-readable format, 144 DPI for Retina).
    /// template = drawn in the bar's text color (xbar templateImage).
    static func decode(_ b64: String, template: Bool) -> NSImage? {
        let clean = b64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              let data = Data(base64Encoded: clean, options: .ignoreUnknownCharacters),
              let img = NSImage(data: data) else { return nil }
        img.isTemplate = template
        return img
    }
}

// MARK: - Plugin runner

final class StatusBarPlugin {
    let url: URL
    let name: String
    let interval: TimeInterval?
    var output = StatusBarOutput.empty
    var onUpdate: (() -> Void)?

    private var running = false

    init(url: URL) {
        self.url = url
        let (name, seconds) = StatusBarInterval.parse(filename: url.lastPathComponent)
        self.name = name
        self.interval = seconds
    }

    /// One-shot run on a utility queue; exactly one flight at a time
    /// (slow plugins skip beats instead of piling up). UI via onUpdate.
    func run() {
        guard !running else { return }
        running = true
        let url = self.url
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let text = Self.execute(url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                if let text { self.output = StatusBarOutput.parse(text) }
                self.onUpdate?()
            }
        }
    }

    static func execute(_ url: URL) -> String? {
        let p = Process()
        p.executableURL = url
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
            + (env["PATH"] ?? "")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(15)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard !p.isRunning else { p.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard data.count < 2_000_000 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Click action. `openInGCT` (set by the canvas) runs terminal=true
    /// commands in a new GCT pane; without it they fall back to Apple's
    /// Terminal.app. href opens, shell runs detached, then optional refresh.
    var openInGCT: ((String, [String]) -> Void)?
    func perform(_ line: StatusBarLine) {
        if let href = line.params.href, let u = URL(string: href) {
            NSWorkspace.shared.open(u)
        }
        if let shell = line.params.shell {
            var args = line.params.shellArgs
            while args.last?.isEmpty == true { args.removeLast() }
            if line.params.terminal {
                if let openInGCT {
                    openInGCT(shell, args)
                } else {
                    let cfg = NSWorkspace.OpenConfiguration()
                    if let app = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: "com.apple.Terminal") {
                        NSWorkspace.shared.open(
                            [URL(fileURLWithPath: shell)], withApplicationAt: app,
                            configuration: cfg, completionHandler: nil)
                    }
                }
            } else {
                DispatchQueue.global(qos: .utility).async {
                    let t = Process()
                    t.executableURL = URL(fileURLWithPath: shell)
                    t.arguments = args
                    t.standardOutput = FileHandle.nullDevice
                    t.standardError = FileHandle.nullDevice
                    try? t.run()
                }
            }
        }
        if line.params.refresh { run() }
    }
}
