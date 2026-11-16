// ⌘P pane browser: every attached session's panes, a section per session, in
// the order you used them, like alt-tab. The look is PickerCard's.
//
//   most recent first            ┌ local ───────┐   a session sits where its
//   [ a(local) b(serenity)       │ a   c        │   freshest pane does; the pane
//     c(local) d(serenity)  ─►   ├ serenity ────┤   you were on before is picked
//     enterprise: not attached ] │ b   d        │
//                                └ enterprise ──┘   a session row is pickable too:
//                                                   it switches there, attaching first

import AppKit
import Common

private let filterPlaceholder = "jump to pane or session…"
private let paneSymbol = "terminal"
private let localSymbol = "laptopcomputer"
private let remoteSymbol = "server.rack"
private let currentMark = "current"

private let jumpHints = [
    PickerHint(key: "⏎", what: "jump"), PickerHint(key: "↑↓", what: "select"),
    PickerHint(key: "esc", what: "close"),
]

// A pane and the session it lives in.
struct SwitcherPane {
    let session: String
    let meta: PaneMeta
}

// A session you can go to, and where it stands ("● 2", "select to attach").
struct SwitcherSession {
    let name: String
    let note: String
}

// What a row does when picked.
private enum Pick {
    case session(String)
    case pane(SwitcherPane)
}

final class SwitcherView: NSView {
    var onSelect: ((String, PaneID) -> Void)?
    var onSession: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private let card = PickerCard(frame: .zero)
    // Most recently used first, the pane you are on leading.
    private var all = [SwitcherPane]()
    private var current: PaneID?
    // Every configured session, attached or not, in config order.
    private var sessions = [SwitcherSession]()
    // What the rows do, in the order they show them.
    private var picks = [Pick]()

    override init(frame: NSRect) {
        super.init(frame: frame)
        card.frame = bounds
        card.autoresizingMask = [.width, .height]
        card.placeholder = filterPlaceholder
        card.hints = jumpHints
        card.onType = { [weak self] in self?.applyFilter($0) }
        card.onEnter = { [weak self] in self?.activate() }
        card.onEscape = { [weak self] in self?.close() }
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // `used` is every pane id, most recent first.
    func present(sessions: [SwitcherSession], panes: [SwitcherPane],
                 used: Recency<PaneID>, current: PaneID?) {
        self.sessions = sessions
        all = used.sorted(panes, by: { $0.meta.id })
        self.current = current
        applyFilter("")
        card.focus()
    }

    func dismiss() {
        removeFromSuperview()
    }

    private func close() {
        dismiss()
        onDismiss?()
    }

    // MARK: List

    private func applyFilter(_ q: String) {
        let needle = q.lowercased()
        let matches = all.filter {
            let hay = (($0.meta.name ?? "") + " " + $0.meta.cwd + " " + $0.meta.host + " " + $0.session).lowercased()
            return needle.isEmpty || hay.contains(needle)
        }

        var items = [PickerItem]()
        picks = []
        for name in shown(for: matches, needle: needle) {
            let symbol = name == LocalHost ? localSymbol : remoteSymbol
            let note = sessions.first { $0.name == name }?.note ?? ""
            items.append(.host(title: name, symbol: symbol, note: note))
            picks.append(.session(name))

            for p in matches where p.session == name {
                items.append(.line(line(of: p)))
                picks.append(.pane(p))
            }
        }

        // Typing picks the best pane; an empty box picks the one you were on before.
        let target = needle.isEmpty ? (matches.dropFirst().first ?? matches.first) : matches.first
        let at = target.flatMap { t in
            picks.firstIndex { if case .pane(let p) = $0 { return p.meta.id == t.meta.id } else { return false } }
        }
        card.setItems(items, select: at.map { .line($0) } ?? .first)
    }

    // Sessions with panes on show, by their freshest pane (`panes` is already by
    // recency); then the others, in config order, if the box doesn't rule them out.
    private func shown(for panes: [SwitcherPane], needle: String) -> [String] {
        var out = [String]()
        for p in panes where !out.contains(p.session) {
            out.append(p.session)
        }

        let rest = sessions.map(\.name).filter {
            !out.contains($0) && (needle.isEmpty || $0.lowercased().contains(needle))
        }

        return out + rest
    }

    // "~/projects/" dim and "gct" bright: the folder is what you know a pane by.
    // A pane whose pty runs on a peer says which one, where "current" would go.
    private func line(of p: SwitcherPane) -> PickerLine {
        let local = p.session == LocalHost
        let path = local ? (p.meta.cwd as NSString).abbreviatingWithTildeInPath : p.meta.cwd
        let folder = (path as NSString).lastPathComponent
        let onPeer = p.meta.host != LocalHost && p.meta.host != p.session
        let trailing = p.meta.id == current ? currentMark : (onPeer ? p.meta.host : "")

        return PickerLine(symbol: paneSymbol, title: p.meta.name ?? "Terminal",
                          subtitle: String(path.dropLast(folder.count)), strong: folder,
                          trailing: trailing)
    }

    private func activate() {
        guard let at = card.picked, at < picks.count else { return }

        let pick = picks[at]
        close()
        switch pick {
        case .session(let name):
            onSession?(name)
        case .pane(let p):
            onSelect?(p.session, p.meta.id)
        }
    }
}
