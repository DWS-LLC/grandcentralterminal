// Rex's rex.block.call, for a GCT pane: a method on the terminal behind it.
//
//   gct.block.call("com.superlogical.terminal", "title", {pane = id})
//        │
//        ├─ from the layout the daemon sent ... title, pwd, process
//        ├─ from the daemon's ring ............ format
//        ├─ to the pane's stdin ............... write
//        ├─ from the canvas, by event ......... size, program_status
//        ├─ to the canvas, as a command ....... reset, set_theme
//        └─ from this machine's disk .......... list_dir
//
// Only the canvas knows a pane's grid and what programs reported on it, so
// those two ask it once (a sync) and answer from what came back.

import Foundation
import Common

private let terminalBlock = "com.superlogical.terminal"
private let syncWait: TimeInterval = 1
private let localHost = LocalHost
private let hexColor = try? NSRegularExpression(pattern: "^#[0-9a-fA-F]{6}$")
private let colorKeys = ["foreground", "background", "cursor"]
private let maxPalette = 16

// How a screen comes back.
private enum Screen: String {
    case text, vt, html
}

final class ScriptBlocks {
    typealias Method = (PaneMeta, ScriptArgs) throws -> Any?

    private let loop: ScriptLoop
    private let dump: (ScriptArgs) throws -> Any?
    private let relay: (CanvasCommand) throws -> Any?
    private let need: (UInt16, String) throws -> Void

    private var session: ScriptSession { loop.session }

    init(loop: ScriptLoop, dump: @escaping (ScriptArgs) throws -> Any?,
         relay: @escaping (CanvasCommand) throws -> Any?, need: @escaping (UInt16, String) throws -> Void) {
        self.loop = loop
        self.dump = dump
        self.relay = relay
        self.need = need
    }

    private lazy var terminal: [String: Method] = [
        "title": { p, _ in ["title": p.title ?? ""] },
        "pwd": { p, _ in ["pwd": "file://" + p.cwd, "cwd": p.cwd] },
        "process": { p, _ in self.process(p) },
        "size": { p, _ in try self.size(p) },
        "program_status": { p, _ in try self.status(p) },
        "format": { p, a in try self.format(p, a) },
        "write": { p, a in try self.write(p, a) },
        "reset": { p, _ in try self.reset(p) },
        "set_theme": { p, a in try self.theme(p, a) },
        "resize": { _, _ in throw ScriptError("resize: the canvas sizes terminals; place the pane with gct.pane.move") },
        "list_dir": { p, a in try self.listDir(p, a) },
    ]

    func call(_ creator: String, _ method: String, _ args: ScriptArgs, on pane: PaneMeta) throws -> Any? {
        guard creator == terminalBlock else { throw ScriptError("no such block kind \(creator) (have: \(terminalBlock))") }
        guard let fn = terminal[method] else {
            throw ScriptError("\(terminalBlock) has no method \(method) (have: \(terminal.keys.sorted().joined(separator: ", ")))")
        }

        return try fn(pane, args)
    }

    // MARK: From the layout

    private func process(_ p: PaneMeta) -> [String: Any] {
        var out = session.processInfo(p)
        out["exited"] = p.exited
        return out
    }

    // MARK: From the canvas

    // Once per script: ask, then wait for the canvas to finish answering. No
    // canvas means no answer; the wait is paid one time and the rest is empty.
    private func synced() throws {
        guard try session.askSync() else { return }

        let before = session.syncs
        loop.pump(until: Date().addingTimeInterval(syncWait), dispatch: .forbid) { self.session.syncs > before }
    }

    private func size(_ p: PaneMeta) throws -> Any? {
        try synced()
        guard let grid = session.grid(of: p.id) else { throw ScriptError("size is only known to the canvas, and it has not said") }

        return grid
    }

    private func status(_ p: PaneMeta) throws -> Any? {
        try synced()
        return ["records": session.records(of: p.id)]
    }

    // MARK: From the ring, to stdin

    // The ring is what the program printed, not the screen it drew: text is
    // that with the escapes stripped, vt is it raw.
    private func format(_ p: PaneMeta, _ a: ScriptArgs) throws -> Any? {
        let raw = try a.string("format") ?? Screen.text.rawValue
        guard let screen = Screen(rawValue: raw) else { throw ScriptError("format is text, vt or html, got \(raw)") }
        guard screen != .html else { throw ScriptError("html isn't available; ask for text or vt") }

        var ask: [String: Any] = ["pane": p.id.description, "strip_ansi": screen == .text]
        if let limit = a.raw["limit"] { ask["limit"] = limit }

        guard var out = try dump(ScriptArgs(raw: ask)) as? [String: Any] else { throw ScriptError("no screen") }

        out["format"] = screen.rawValue
        return out
    }

    // Bytes as typed: no newline added, unlike gct.pane.send.
    private func write(_ p: PaneMeta, _ a: ScriptArgs) throws -> Any? {
        var bytes: Data
        switch a.raw["text"] ?? a.raw["data"] {
        case let s as String: bytes = Data(s.utf8)
        case let d as Data: bytes = d
        default: throw ScriptError("text must be a string")
        }
        guard !bytes.isEmpty else { throw ScriptError("text is empty") }

        try session.sendKeys(p.id, bytes)
        return [:] as [String: Any]
    }

    // MARK: To the canvas

    private func reset(_ p: PaneMeta) throws -> Any? {
        try need(EventProtoVersion, "reset")
        return try relay(CanvasCommand(verb: .reset, pane: p.id))
    }

    // foreground, background, cursor as "#rrggbb", and palette: a list whose
    // first entry is color 0.
    private func theme(_ p: PaneMeta, _ a: ScriptArgs) throws -> Any? {
        try need(EventProtoVersion, "set_theme")

        var colors = [String: String]()
        for key in colorKeys {
            guard let value = try a.string(key) else { continue }

            colors[key] = try color(value, key)
        }

        let palette = try a.list("palette")
        guard palette.count <= maxPalette else { throw ScriptError("palette has at most \(maxPalette) colors") }

        for (i, item) in palette.enumerated() {
            guard let value = item as? String else { throw ScriptError("palette is a list of #rrggbb strings") }

            colors[String(i)] = try color(value, "palette[\(i + 1)]")
        }
        guard !colors.isEmpty else { throw ScriptError("set_theme needs foreground, background, cursor or palette") }

        return try relay(CanvasCommand(verb: .theme, pane: p.id, colors: colors))
    }

    private func color(_ s: String, _ what: String) throws -> String {
        guard hexColor?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil else {
            throw ScriptError("\(what) is #rrggbb, got \(s)")
        }

        return s
    }

    // MARK: From disk

    // The directories under a path (default: the pane's cwd), names only,
    // dot-directories left out unless hidden=true. Reads this machine's disk.
    private func listDir(_ p: PaneMeta, _ a: ScriptArgs) throws -> Any? {
        guard p.host == localHost else { throw ScriptError("list_dir reads this machine's disk; the pane runs on \(p.host)") }

        let given = try a.string("path") ?? p.cwd
        let path = given.hasPrefix("/") ? given : (given.hasPrefix("~") ? NSString(string: given).expandingTildeInPath : p.cwd + "/" + given)
        let hidden = try a.flag("hidden")

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            throw ScriptError("can't read \(path)")
        }

        let dirs = names.filter { name in
            guard hidden || !name.hasPrefix(".") else { return false }

            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path + "/" + name, isDirectory: &isDir) && isDir.boolValue
        }
        return ["path": path, "dirs": dirs.sorted()]
    }
}
