// ⌘⇧P command palette: type-to-filter, arrows/enter to run. Built on the pane
// switcher's bones; what is in the list is CanvasPalette's business.
//
//   pick ── no args ───────────────────────────────► run
//     └── args ──► ask 1 ──► ask 2 ──► ... ──► run(answers as a JSON object)
//                  ⏎ answers (blank skips an optional one) · esc steps back to the list
//
// The list stage filters as you type. An ask stage reuses the field for the
// answer and the table for what is being asked and what was said so far.

import AppKit
import Common

private let rowHeight: CGFloat = 28
private let detailAlpha: CGFloat = 0.55
private let titleSize: CGFloat = 13
private let detailSize: CGFloat = 11
private let listPlaceholder = "run a command…"

// One line of the palette: what it says, what it is matched on, what it does.
struct PaletteRow {
    let title: String
    // The description, or the key an action is on.
    let detail: String
    // Asked for one by one before `run`; empty: it runs at once.
    let args: [PaletteArg]
    let text: PaletteText
    // Gets the answers as a JSON object, nil when nothing was asked.
    let run: (String?) -> Void
}

private struct Line {
    let title: String
    let detail: String
}

// An action half-way through its questions.
private struct Asking {
    let row: PaletteRow
    var left: [PaletteArg]
    // What was typed for each answered one, to show back.
    var said: [(arg: PaletteArg, shown: String)] = []
    var answers: [String: Any] = [:]
    var problem: String?
}

private enum Typed {
    case clear, keep
}

final class PaletteView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onDismiss: (() -> Void)?

    private let field = NSTextField(frame: .zero)
    private let table = NSTableView(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private var rows = [PaletteRow]()
    private var shown = [PaletteRow]()
    private var lines = [Line]()
    private var asking: Asking?
    // What was typed in the list, for when esc steps back to it.
    private var query = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = GCTTheme.current.switcherBackground.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = GCTTheme.current.switcherBorder.cgColor
        layer?.shadowOpacity = 0.6
        layer?.shadowRadius = 30

        field.isBordered = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        field.textColor = .white
        field.placeholderString = listPlaceholder
        field.delegate = self
        field.frame = NSRect(x: 16, y: frame.height - 44, width: frame.width - 32, height: 28)
        field.autoresizingMask = [.maxXMargin, .minYMargin]
        addSubview(field)

        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.addTableColumn(NSTableColumn(identifier: .init("p")))
        table.doubleAction = #selector(activateRow)
        table.target = self

        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.backgroundColor = .clear
        scroll.drawsBackground = false
        scroll.frame = NSRect(x: 10, y: 10, width: frame.width - 20, height: frame.height - 64)
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    func present(_ rows: [PaletteRow]) {
        self.rows = rows
        asking = nil
        applyFilter("")
        window?.makeFirstResponder(field)
    }

    func dismiss() {
        removeFromSuperview()
    }

    // MARK: List

    private func applyFilter(_ query: String) {
        shown = PaletteRank.order(rows.map(\.text), query: query).map { rows[$0] }
        lines = shown.map { Line(title: $0.title, detail: $0.detail) }
        table.reloadData()
        if !shown.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    private func moveSelection(_ delta: Int) {
        guard asking == nil, !shown.isEmpty else { return }

        let next = min(shown.count - 1, max(0, max(0, table.selectedRow) + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // The picked row runs, or starts asking for what it needs.
    private func choose() {
        let row = max(0, table.selectedRow)
        guard row < shown.count else { return }

        let chosen = shown[row]
        guard !chosen.args.isEmpty else {
            finish(chosen, answers: nil)
            return
        }

        query = field.stringValue
        asking = Asking(row: chosen, left: chosen.args)
        showQuestion(.clear)
    }

    // Closes first, so the action finds the canvas focused, as a key would.
    private func finish(_ chosen: PaletteRow, answers: String?) {
        dismiss()
        onDismiss?()
        chosen.run(answers)
    }

    // MARK: Questions

    private func showQuestion(_ typed: Typed) {
        guard let a = asking, let arg = a.left.first else { return }

        if typed == .clear {
            field.stringValue = ""
        }

        let skip = arg.optional ? ", ⏎ skips" : ""
        field.placeholderString = "\(arg.name) (\(arg.hint)\(skip))…"

        var out = [Line(title: a.row.title, detail: a.row.detail)]
        out += a.said.map { Line(title: "   \($0.arg.name) = \($0.shown)", detail: "") }
        out.append(Line(title: "▸ \(arg.name)", detail: a.problem ?? arg.hint + (arg.optional ? ", optional" : "")))
        lines = out
        table.reloadData()
        table.deselectAll(nil)
    }

    // ⏎ in a question: take the answer, or say what is wrong with it.
    private func answer() {
        guard var a = asking, let arg = a.left.first else { return }

        let input = field.stringValue
        guard !input.isEmpty else {
            guard arg.optional else {
                complain("needs an answer")
                return
            }

            advance(a)
            return
        }

        guard let value = arg.value(of: input) else {
            complain("expects \(arg.hint)")
            return
        }

        a.answers[arg.name] = value.json
        a.said.append((arg, input))
        advance(a)
    }

    private func complain(_ problem: String) {
        asking?.problem = problem
        showQuestion(.keep)
    }

    // The next question, or the last one answered: run.
    private func advance(_ was: Asking) {
        var a = was
        a.left.removeFirst()
        a.problem = nil
        asking = a

        guard a.left.isEmpty else {
            showQuestion(.clear)
            return
        }

        finish(a.row, answers: json(a.answers))
    }

    private func json(_ answers: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // esc: out of a question, back to the list as it was; out of the list, away.
    private func cancel() {
        guard asking != nil else {
            dismiss()
            onDismiss?()
            return
        }

        asking = nil
        field.stringValue = query
        field.placeholderString = listPlaceholder
        applyFilter(query)
    }

    @objc private func activateRow() {
        guard asking == nil else { return }

        choose()
    }

    // MARK: Field delegate

    func controlTextDidChange(_ obj: Notification) {
        guard asking == nil else { return }

        applyFilter(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if asking == nil { choose() } else { answer() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1); return true
        default:
            return false
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let r = lines[row]
        let color = GCTTheme.current.switcherText
        let line = NSMutableAttributedString(string: r.title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: titleSize, weight: .regular),
            .foregroundColor: color,
        ])
        if !r.detail.isEmpty {
            line.append(NSAttributedString(string: "   " + r.detail, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: detailSize, weight: .regular),
                .foregroundColor: color.withAlphaComponent(detailAlpha),
            ]))
        }

        let text = NSTextField(labelWithAttributedString: line)
        text.lineBreakMode = .byTruncatingTail
        return text
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight }
}
