// What only the canvas can see, told to scripts (`gctd lua`).
//
//   libghostty ──► progress, clipboard ─┐
//   ProgramStatusStore ──► deltas ──────┼─► reportEvent ─► hub ─► daemon ─► subscribers
//   grid resize ──► state.size ─────────┘
//
//   daemon ─► canvasRelay: sync   ─► every record and size again, as events
//                          reset  ─► RIS into the pane's emulator
//                          theme  ─► OSC 10/11/12/4 into the pane's emulator
//
// Reset and theme only touch what is drawn: nothing reaches the program.

import AppKit
import Common

private let reasonSnapshot = "snapshot"
private let reasonReport = "report"
private let ris = "\u{1B}c"
private let hexColor = try? NSRegularExpression(pattern: "^#?[0-9a-fA-F]{6}$")
private let maxPaletteIndex = 15

// OSC numbers for the named colors; palette entries use OSC 4 ; n.
private let oscColors = ["foreground": 10, "background": 11, "cursor": 12]

extension CanvasView {
    // MARK: Reporting

    private func send(_ id: PaneID, _ name: String, _ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }

        hub.reportEvent(PaneEvent(id: id, name: name, payload: String(decoding: data, as: UTF8.self)))
    }

    func surfaceProgress(_ host: SurfaceHost, state: String, progress: Int?) {
        var fields: [String: Any] = ["state": state]
        if let progress { fields["progress"] = progress }

        send(host.paneID, PaneEventName.progress, fields)
    }

    func surfaceClipboard(_ host: SurfaceHost, text: String) {
        send(host.paneID, PaneEventName.clipboard, ["text": text])
    }

    // Wired once, in setup: every live change to a pane's status records.
    func reportStatus() {
        programStatus.onDelta = { [weak self] pane, delta in
            self?.report(pane, delta, reason: reasonReport)
        }
    }

    private func report(_ pane: PaneID, _ delta: ProgramDelta, reason: String) {
        for rec in delta.changed {
            send(pane, PaneEventName.statusChanged, ["id": rec.id, "record": rec.json, "reason": reason])
        }

        // One event per reason: a prompt and a clear can land in one chunk.
        let byReason = Dictionary(grouping: delta.removed, by: \.reason)
        for (why, gone) in byReason.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            send(pane, PaneEventName.statusRemoved, ["ids": gone.map(\.id), "reason": why.rawValue])
        }
    }

    // The grid, for block.call's size. Points: columns times a cell's width.
    func reportSize(_ host: SurfaceHost, cols: UInt16, rows: UInt16) {
        var fields: [String: Any] = ["cols": Int(cols), "rows": Int(rows)]
        if let m = host.surfaceMetrics() {
            fields["width"] = Double(cols) * m.cellWidth
            fields["height"] = Double(rows) * m.cellHeight
        }

        send(host.paneID, PaneEventName.sizeState, fields)
    }

    // MARK: Commands from scripts

    // Everything one daemon's panes know, again: a script that starts late
    // learns what it missed. Records come back marked as a snapshot.
    func syncScripts(owner: String) {
        for pane in canvases.values.flatMap({ $0.panes.values }) where hub.owner(of: pane.id) == owner {
            let all = programStatus.records(for: pane.id)
            report(pane.id, ProgramDelta(changed: all, removed: []), reason: reasonSnapshot)

            guard let host = pane.host, let m = host.surfaceMetrics() else { continue }

            reportSize(host, cols: m.cols, rows: m.rows)
        }

        // On the owner's own link, behind everything above: a script waits for it.
        hub.conn(forOwner: owner)?.reportEvent(PaneEvent(id: nil, name: PaneEventName.synced))
    }

    func scriptedReset(_ cmd: CanvasCommand) {
        emulate(cmd.pane, ris)
    }

    // foreground/background/cursor as #rrggbb, and "0"..."15" for the palette.
    func scriptedTheme(_ cmd: CanvasCommand) {
        var out = ""
        for (key, value) in (cmd.colors ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let rgb = Self.oscRGB(value) else { continue }

            if let code = oscColors[key] {
                out += "\u{1B}]\(code);\(rgb)\u{1B}\\"
            } else if let n = Int(key), (0...maxPaletteIndex).contains(n) {
                out += "\u{1B}]4;\(n);\(rgb)\u{1B}\\"
            }
        }

        emulate(cmd.pane, out)
    }

    // "#1e90ff" -> "rgb:1e/90/ff"; anything else is not a color.
    private static func oscRGB(_ s: String) -> String? {
        let range = NSRange(s.startIndex..., in: s)
        guard hexColor?.firstMatch(in: s, range: range) != nil else { return nil }

        let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        let pairs = stride(from: 0, to: 6, by: 2).map { i -> String in
            let a = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[a..<hex.index(a, offsetBy: 2)])
        }
        return "rgb:" + pairs.joined(separator: "/")
    }

    // Draw-only: the bytes go to the emulator as if the program printed them.
    private func emulate(_ id: PaneID?, _ text: String) {
        guard let id, !text.isEmpty else { return }

        for pane in canvases.values.compactMap({ $0.panes[id] }) {
            pane.host?.feed(Data(text.utf8))
        }
    }
}
