// ⌘⇧P command palette: type-to-filter, arrows/enter to run. Built on the pane
// switcher's bones; what is in the list is CanvasPalette's business.

import AppKit
import Common

private let rowHeight: CGFloat = 28
private let detailAlpha: CGFloat = 0.55
private let titleSize: CGFloat = 13
private let detailSize: CGFloat = 11

// One line of the palette: what it says, what it is matched on, what it does.
struct PaletteRow {
    let title: String
    // The description, or the key an action is on.
    let detail: String
    let text: PaletteText
    let run: () -> Void
}

final class PaletteView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onDismiss: (() -> Void)?

    private let field = NSTextField(frame: .zero)
    private let table = NSTableView(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private var rows = [PaletteRow]()
    private var shown = [PaletteRow]()

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
        field.placeholderString = "run a command…"
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
        applyFilter("")
        window?.makeFirstResponder(field)
    }

    func dismiss() {
        removeFromSuperview()
    }

    private func applyFilter(_ query: String) {
        shown = PaletteRank.order(rows.map(\.text), query: query).map { rows[$0] }
        table.reloadData()
        if !shown.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    // MARK: Field delegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            activateRow()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(); onDismiss?()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1); return true
        default:
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !shown.isEmpty else { return }

        let next = min(shown.count - 1, max(0, max(0, table.selectedRow) + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // Closes first, so the action finds the canvas focused, as a key would.
    @objc private func activateRow() {
        let row = max(0, table.selectedRow)
        guard row < shown.count else { return }

        let chosen = shown[row]
        dismiss()
        onDismiss?()
        chosen.run()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let r = shown[row]
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
