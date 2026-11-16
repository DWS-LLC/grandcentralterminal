// ⌘⇧P command palette: type-to-filter, arrows/enter to run. The look is
// PickerCard's; what is in the list is CanvasPalette's business, and it is the
// list of the session on screen.
//
//   pick ── no args ───────────────────────────────► run
//     └── args ──► ask 1 ──► ask 2 ──► ... ──► run(answers as a JSON object)
//                  ⏎ answers (blank skips an optional one) · esc steps back to the list
//
// The list stage filters as you type; with nothing typed it reads as a menu,
// one section per category. An ask stage reuses the field for the answer and
// the table for what is being asked and what was said so far.

import AppKit
import Common

private let listPlaceholder = "run a command…"
private let uncategorized = "Scripts"
private let actionSymbol = "bolt.fill"
private let saidSymbol = "checkmark"
private let askSymbol = "chevron.right"
private let problemSymbol = "exclamationmark.triangle"

private let listHints = [
    PickerHint(key: "⏎", what: "run"), PickerHint(key: "↑↓", what: "select"),
    PickerHint(key: "esc", what: "close"),
]
private let askHints = [
    PickerHint(key: "⏎", what: "answer"), PickerHint(key: "esc", what: "back"),
]

// One line of the palette: what it says, what it is matched on, what it does.
struct PaletteRow {
    let title: String
    // The script's description; empty for GCT's own actions.
    let detail: String
    // The key an action is on, if any.
    let keys: String
    let symbol: String
    // Asked for one by one before `run`; empty: it runs at once.
    let args: [PaletteArg]
    let text: PaletteText
    // Gets the answers as a JSON object, nil when nothing was asked.
    let run: (String?) -> Void
    // What the history remembers it by.
    let historyKey: String
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

final class PaletteView: NSView {
    var onDismiss: (() -> Void)?

    private let card = PickerCard(frame: .zero)
    private var rows = [PaletteRow]()
    private var shown = [PaletteRow]()
    private var asking: Asking?
    // What was typed in the list, for when esc steps back to it.
    private var query = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        card.frame = bounds
        card.autoresizingMask = [.width, .height]
        card.placeholder = listPlaceholder
        card.hints = listHints
        card.onType = { [weak self] in self?.typed($0) }
        card.onEnter = { [weak self] in self?.enter() }
        card.onEscape = { [weak self] in self?.cancel() }
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // `session` is whose actions these are: the one on screen.
    func present(_ rows: [PaletteRow], session: String) {
        self.rows = rows
        asking = nil
        card.badge = session
        applyFilter("")
        card.focus()
    }

    func dismiss() {
        removeFromSuperview()
    }

    // MARK: List

    private func applyFilter(_ query: String) {
        shown = PaletteRank.order(rows.map(\.text), query: query).map { rows[$0] }
        card.setItems(listItems(typed: query), select: .first)
    }

    // Nothing typed: a menu, a section per category. Typed: the ranking, flat,
    // each row saying its category where it would say its keys.
    private func listItems(typed query: String) -> [PickerItem] {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return shown.map { .line(line(of: $0, trailing: $0.keys.isEmpty ? $0.text.category : $0.keys)) }
        }

        var out = [PickerItem]()
        var last: String?
        for row in shown {
            if row.text.category != last {
                let title = row.text.category.isEmpty ? uncategorized : row.text.category
                out.append(.section(title: title, symbol: row.symbol))
                last = row.text.category
            }
            out.append(.line(line(of: row, trailing: row.keys)))
        }

        return out
    }

    private func line(of row: PaletteRow, trailing: String) -> PickerLine {
        PickerLine(symbol: row.symbol, title: row.title, subtitle: row.detail, trailing: trailing)
    }

    // The picked row runs, or starts asking for what it needs.
    private func choose() {
        let at = card.picked ?? 0
        guard at < shown.count else { return }

        let chosen = shown[at]
        guard !chosen.args.isEmpty else {
            finish(chosen, answers: nil)
            return
        }

        query = card.text
        asking = Asking(row: chosen, left: chosen.args)
        card.hints = askHints
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
            card.text = ""
        }

        let skip = arg.optional ? ", ⏎ skips" : ""
        card.placeholder = "\(arg.name) (\(arg.hint)\(skip))…"

        var out = [PickerItem.line(PickerLine(symbol: actionSymbol, title: a.row.title, subtitle: a.row.detail))]
        out += a.said.map { .line(PickerLine(symbol: saidSymbol, title: "\($0.arg.name) = \($0.shown)")) }

        let hint = arg.hint + (arg.optional ? ", optional" : "")
        out.append(.line(PickerLine(symbol: a.problem == nil ? askSymbol : problemSymbol,
                                    title: arg.name, subtitle: a.problem ?? hint)))
        card.setItems(out, select: .none)
    }

    // ⏎ in a question: take the answer, or say what is wrong with it.
    private func answer() {
        guard var a = asking, let arg = a.left.first else { return }

        let input = card.text
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
        card.text = query
        card.placeholder = listPlaceholder
        card.hints = listHints
        applyFilter(query)
    }

    // MARK: Card events

    private func typed(_ text: String) {
        guard asking == nil else { return }

        applyFilter(text)
    }

    private func enter() {
        if asking == nil {
            choose()
        } else {
            answer()
        }
    }
}
