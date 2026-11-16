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
// The palette lists only the session on screen's scripts: a pick runs on that
// session's daemon.

import AppKit
import Common

private let builtInCategory = "GCT"
// What the script's side prints in errors, where a bound key would say its keys.
private let pickLabel = "palette"
private let pickOrigin = "palette"
private let historyKey = "paletteHistory"
private let historyLimit = 100
private let builtInSymbol = "macwindow"
private let scriptSymbol = "curlybraces"

// Every script's list, by script token, and the daemon each runs against.
final class PaletteStore {
    struct Listed {
        let token: String
        let owner: String
        let entry: PaletteWire.Entry
    }

    private var lists = [String: (owner: String, entries: [PaletteWire.Entry])]()
    // What was run, newest first, kept across launches. Keyed "gct:<action>" or
    // "<session>:<script action>": two sessions can each have an "open_notes".
    private(set) var ran = Recency<String>(
        keys: UserDefaults.standard.stringArray(forKey: historyKey) ?? [], limit: historyLimit)

    func didRun(_ key: String) {
        ran.touch(key)
        UserDefaults.standard.set(ran.keys, forKey: historyKey)
    }

    func replace(_ wire: PaletteWire, owner: String) {
        lists[wire.token] = (owner, wire.entries)
    }

    func remove(token: String) {
        lists[token] = nil
    }

    func remove(owner: String) {
        lists = lists.filter { $0.value.owner != owner }
    }

    // What one session's scripts published, and no other's: a pick runs on
    // that daemon, so another session's entries would act on the wrong machine.
    // Stable: by category, then title, so the empty query reads as a menu.
    func all(owner: String) -> [Listed] {
        let flat = lists.filter { $0.value.owner == owner }.flatMap { token, list in
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

    // GCT's own actions first, then the session on screen's scripts (a pick
    // runs on that session's daemon). Inside each category, what you ran last
    // comes first; what you never ran keeps its place.
    func paletteRows() -> [PaletteRow] {
        let ran = paletteStore.ran
        let builtIns = GCTAction.allCases.filter { $0 != .commandPalette }.map { action -> PaletteRow in
            let title = Self.title(of: action)
            let keys = GCTConfig.current.keybinds[action]?.description ?? ""
            let key = "\(builtInCategory.lowercased()):\(action.rawValue)"
            return PaletteRow(
                title: title, detail: "", keys: keys, symbol: builtInSymbol, args: [],
                text: PaletteText(title: title, category: builtInCategory, keywords: action.rawValue),
                run: { [weak self] _ in
                    self?.paletteStore.didRun(key)
                    self?.runCanvasCommand(CanvasCommand(verb: .action, action: action.rawValue))
                },
                historyKey: key)
        }

        let scripts = paletteStore.all(owner: session).map { listed -> PaletteRow in
            let e = listed.entry
            let detail = e.description ?? ""
            let key = "\(session):\(e.name)"
            return PaletteRow(
                title: e.title, detail: detail, keys: "", symbol: scriptSymbol, args: e.args ?? [],
                text: PaletteText(title: e.title, category: e.category ?? "", keywords: e.keywords ?? "", detail: detail),
                run: { [weak self] answers in
                    self?.paletteStore.didRun(key)
                    self?.pick(listed, answers: answers)
                },
                historyKey: key)
        }

        return ran.sorted(builtIns, by: \.historyKey) + sortedInCategories(scripts, ran)
    }

    // Categories stay in the store's (alphabetical) order; recency orders inside each.
    private func sortedInCategories(_ rows: [PaletteRow], _ ran: Recency<String>) -> [PaletteRow] {
        var categories = [String]()
        for row in rows where !categories.contains(row.text.category) {
            categories.append(row.text.category)
        }

        return categories.flatMap { category in
            ran.sorted(rows.filter { $0.text.category == category }, by: \.historyKey)
        }
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
