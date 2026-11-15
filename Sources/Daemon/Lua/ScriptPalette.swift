// gct.action{title=..}: one script's entries in the command palette. The script
// keeps the list, the canvas shows it, and a pick comes back as the same
// state.key event a bound key sends (origin "palette").
//
//   gct.action ─► ScriptPalette ─► PaletteWire ─► daemon ─► canvas palette
//                      ▲                                        │ pick
//                      └──────── state.key event ◄── daemon ◄───┘
//
// An action without a title stays out of the palette: it is for gct.invoke and
// key bindings. The daemon takes the list down when the script's connection
// closes, so a script that dies leaves nothing behind.

import Foundation
import Common

final class ScriptPalette {
    // One script can't bury the palette.
    static let maxEntries = 1_024

    private let token: String
    private let publish: (PaletteWire) -> Void
    private var entries = [PaletteWire.Entry]()
    // False while the script first runs: its actions go out together, once, not one by one.
    private var live = false

    init(token: String, publish: @escaping (PaletteWire) -> Void) {
        self.token = token
        self.publish = publish
    }

    // Enough to keep the script alive: a palette-only script has no handlers.
    var hasEntries: Bool { !entries.isEmpty }

    var count: Int { entries.count }

    // The palette entry for gct.action's spec, nil when it has no title.
    static func entry(name: String, spec: [String: Any]) throws -> PaletteWire.Entry? {
        guard let title = spec["title"] as? String, !title.isEmpty else { return nil }

        return PaletteWire.Entry(name: name, title: title,
                                 description: spec["description"] as? String,
                                 category: spec["category"] as? String,
                                 keywords: keywords(spec["keywords"]),
                                 args: try args(spec["args"]))
    }

    // Rex's `args = { count = "integer", note = "string?" }`. A table has no
    // order, so they are asked by name.
    private static func args(_ raw: Any?) throws -> [PaletteArg]? {
        guard let raw else { return nil }
        guard let table = raw as? [String: Any] else {
            throw ScriptError("args is a table of name = type, like { count = \"integer\", note = \"string?\" }")
        }

        return try table.sorted { $0.key < $1.key }.map { name, spec in
            guard let spec = spec as? String else {
                throw ScriptError("args.\(name) is a type like \"string\", \"number?\", \"integer\" or \"boolean\"")
            }

            return PaletteArg(name: name, spec: spec)
        }
    }

    // Rex writes them as one string; a list of words is fine too.
    private static func keywords(_ raw: Any?) -> String? {
        if let text = raw as? String { return text }

        return (raw as? [Any])?.compactMap { $0 as? String }.joined(separator: " ")
    }

    // Redefining an action replaces its entry, or drops it when it lost its title.
    func set(_ name: String, _ entry: PaletteWire.Entry?) {
        entries.removeAll { $0.name == name }
        if let entry {
            entries.append(entry)
        }

        guard live else { return }

        // Possibly empty: that takes the last one down.
        publish(wire)
    }

    // The script's first run is over: everything it defined goes out now.
    func flush() {
        live = true
        resend()
    }

    // A canvas that came up after the script has none of it. A script with
    // nothing to show has nothing to say.
    func resend() {
        guard !entries.isEmpty else { return }

        publish(wire)
    }

    private var wire: PaletteWire {
        PaletteWire(token: token, entries: entries)
    }
}
