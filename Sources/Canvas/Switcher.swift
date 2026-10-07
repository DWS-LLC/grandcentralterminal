// ⌘P pane switcher: type-to-filter, arrows/enter, jump with camera zoom.

import AppKit
import Common

final class SwitcherView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((PaneID) -> Void)?
    var onDismiss: (() -> Void)?

    private let field = NSTextField(frame: .zero)
    private let table = NSTableView(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private var all = [PaneMeta]()
    private var order = [PaneID]()
    private var filtered = [PaneMeta]()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.97).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.25, alpha: 1).cgColor
        layer?.shadowOpacity = 0.6
        layer?.shadowRadius = 30

        field.isBordered = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        field.textColor = .white
        field.placeholderString = "jump to pane…"
        field.delegate = self
        field.frame = NSRect(x: 16, y: frame.height - 44, width: frame.width - 32, height: 28)
        field.autoresizingMask = [.maxXMargin, .minYMargin]
        addSubview(field)

        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 0)
        let col = NSTableColumn(identifier: .init("p"))
        table.addTableColumn(col)
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

    func present(_ panes: [PaneMeta], order: [PaneID]) {
        all = panes
        self.order = order
        applyFilter("")
        window?.makeFirstResponder(field)
    }

    func dismiss() {
        removeFromSuperview()
    }

    private func applyFilter(_ q: String) {
        let needle = q.lowercased()
        let rows = order.compactMap { id -> PaneMeta? in
            guard let m = all.first(where: { $0.id == id }) else { return nil }
            let hay = ((m.name ?? "") + " " + m.cwd + " " + m.host).lowercased()
            return needle.isEmpty || hay.contains(needle) ? m : nil
        }
        filtered = rows
        table.reloadData()
        if !filtered.isEmpty {
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
        guard !filtered.isEmpty else { return }
        let current = max(0, table.selectedRow)
        let next = min(filtered.count - 1, max(0, current + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func activateRow() {
        let row = max(0, table.selectedRow)
        guard row < filtered.count else { return }
        let id = filtered[row].id
        dismiss()
        onDismiss?()
        onSelect?(id)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let m = filtered[row]
        let text = NSTextField(labelWithString:
            "\(m.name ?? "Terminal")  ·  \(m.cwd)  ·  \(m.host)")
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = (m.id == order.last) ? .white : NSColor(white: 0.75, alpha: 1)
        return text
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 26 }
}
