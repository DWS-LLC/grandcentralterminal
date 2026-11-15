// The command palette's contents: GCT's own actions, and whatever scripts and
// plugins publish with gct.action{title=..}.
//
//   script ─► daemon ─► canvasRelay(.palette) ─► PaletteStore ─┐
//   GCTAction.allCases ────────────────────────────────────────┴─► rows ─► PaletteView
//
//   a pick:  built-in  ─► runs as `gctd do <action>` does
//            script's  ─► state.key (origin "palette") on its daemon's link ─► the script
//
// A script's entries go when its daemon's link does, like its key bindings.

import AppKit
import Common

private let builtInCategory = "GCT"
// What the script's side prints in errors, where a bound key would say its keys.
private let pickLabel = "palette"
private let pickOrigin = "palette"

// Every script's list, by script token, and the daemon each runs against.
final class PaletteStore {
    struct Listed {
        let token: String
        let owner: String
        let entry: PaletteWire.Entry
    }

    private var lists = [String: (owner: String, entries: [PaletteWire.Entry])]()

    func replace(_ wire: PaletteWire, owner: String) {
        lists[wire.token] = (owner, wire.entries)
    }

    func remove(token: String) {
        lists[token] = nil
    }

    func remove(owner: String) {
        lists = lists.filter { $0.value.owner != owner }
    }

    // Stable: by category, then title, so the empty query reads as a menu.
    var all: [Listed] {
        let flat = lists.flatMap { token, list in
            list.entries.map { Listed(token: token, owner: list.owner, entry: $0) }
        }

        return flat.sorted {
            let a = ($0.entry.category ?? "", $0.entry.title)
            let b = ($1.entry.category ?? "", $1.entry.title)
            return a < b
        }
    }
}

extension CanvasView {
    // A script's whole list, or an empty one taking it down.
    func scriptedPalette(_ cmd: CanvasCommand, owner: String) {
        guard let wire = cmd.palette else { return }

        if wire.isEmpty {
            paletteStore.remove(token: wire.token)
        } else {
            paletteStore.replace(wire, owner: owner)
        }
    }

    // A daemon went away: so did the entries its scripts put here.
    func dropPalette(owner: String) {
        paletteStore.remove(owner: owner)
    }

    // The scripts' entries first (they are what you added), then GCT's own.
    func paletteRows() -> [PaletteRow] {
        let scripts = paletteStore.all.map { listed -> PaletteRow in
            let e = listed.entry
            let detail = e.description ?? ""
            return PaletteRow(
                title: e.title, detail: detail, args: e.args ?? [],
                text: PaletteText(title: e.title, category: e.category ?? "", keywords: e.keywords ?? "", detail: detail),
                run: { [weak self] answers in self?.pick(listed, answers: answers) })
        }

        let builtIns = GCTAction.allCases.filter { $0 != .commandPalette }.map { action -> PaletteRow in
            let title = Self.title(of: action)
            let keys = GCTConfig.current.keybinds[action]?.description ?? ""
            return PaletteRow(
                title: title, detail: keys, args: [],
                text: PaletteText(title: title, category: builtInCategory, keywords: action.rawValue),
                run: { [weak self] _ in self?.runCanvasCommand(CanvasCommand(verb: .action, action: action.rawValue)) })
        }

        return scripts + builtIns
    }

    // "open-new-window-above" reads "Open New Window Above".
    private static func title(of action: GCTAction) -> String {
        action.rawValue.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // `answers` is the JSON object of what the palette asked for; nil when it asked nothing.
    private func pick(_ listed: PaletteStore.Listed, answers: String?) {
        var what: [String: Any] = ["action": listed.entry.name, "key": pickLabel, "origin": pickOrigin]
        if let answers { what["args"] = answers }

        _ = tellScript(listed.token, owner: listed.owner, what)
    }
}
