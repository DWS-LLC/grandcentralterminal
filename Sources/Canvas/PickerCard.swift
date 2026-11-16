// The look the ⌘P pane picker and the ⌘⇧P palette share.
//
//   ┌────────────────────────────────────────────────┐
//   │ ⌕  jump to pane…                     ⟨ local ⟩ │  search pill + the session it acts on
//   │                                                │
//   │ ▭  local                                       │  section
//   │ ▌>_ zsh                               current  │  picked row: accent bar + wash
//   │     ~/projects/tmuxInfiniteCanvas              │
//   │ ────────────────────────────────────────────── │
//   │ ⏎ jump   ↑↓ select   esc close                 │  key hints
//   └────────────────────────────────────────────────┘
//
// The owner feeds it items and hears typing, enter and esc. It keeps no model.

import AppKit

private let cardCorner: CGFloat = 14
private let cardInset: CGFloat = 12
private let pillHeight: CGFloat = 38
private let pillCorner: CGFloat = 10
private let pillWash: CGFloat = 0.07
private let hintsHeight: CGFloat = 34
private let ruleHeight: CGFloat = 1
private let rowInset: CGFloat = 4
private let rowCorner: CGFloat = 8
private let rowWash: CGFloat = 0.10
private let barWidth: CGFloat = 3
private let barInset: CGFloat = 8
private let sectionHeight: CGFloat = 30
private let lineHeight: CGFloat = 32
private let lineHeightTall: CGFloat = 46
private let cellPad: CGFloat = 14
private let iconSize: CGFloat = 16
private let textLeft: CGFloat = 42
private let dimAlpha: CGFloat = 0.55
private let faintAlpha: CGFloat = 0.38
private let fieldSize: CGFloat = 14
private let titleSize: CGFloat = 13
private let subtitleSize: CGFloat = 11
private let badgeSize: CGFloat = 11
private let badgePad: CGFloat = 8
private let badgeHeight: CGFloat = 20
private let hintGap = "    "
private let searchSymbol = "magnifyingglass"

struct PickerLine {
    var symbol: String
    var title: String
    var subtitle = ""
    // The tail of the subtitle, drawn brighter: the folder at the end of a path.
    var strong = ""
    var trailing = ""
}

enum PickerItem {
    case section(title: String, symbol: String)
    // A section header you can pick, with a word on its right.
    case host(title: String, symbol: String, note: String)
    case line(PickerLine)
}

enum PickerSelect {
    // The first line is picked and the arrows move it.
    case first
    // The nth pickable row (plain sections don't count) is picked, and the arrows move it.
    case line(Int)
    // Nothing to pick: the lines are only there to read.
    case none
}

struct PickerHint {
    let key: String
    let what: String
}

final class PickerCard: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onType: ((String) -> Void)?
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var placeholder = "" {
        didSet { dimPlaceholder() }
    }

    // The session the picker acts on, in the corner of the search pill.
    var badge = "" {
        didSet {
            badgeView.text = badge
            needsLayout = true
        }
    }

    var hints = [PickerHint]() {
        didSet { showHints() }
    }

    // The picked row, counting pickable rows only (plain sections don't count).
    var picked: Int? {
        lineRows.firstIndex(of: table.selectedRow)
    }

    private let pill = NSView(frame: .zero)
    private let glass = NSImageView(frame: .zero)
    private let field = NSTextField(frame: .zero)
    private let badgeView = PickerBadge(frame: .zero)
    private let table = NSTableView(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private let rule = NSView(frame: .zero)
    private let hintLabel = NSTextField(labelWithString: "")
    private var items = [PickerItem]()
    // The table row of each line, in order.
    private var lineRows = [Int]()
    private var selectable = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let theme = GCTTheme.current

        wantsLayer = true
        layer?.backgroundColor = theme.switcherBackground.cgColor
        layer?.cornerRadius = cardCorner
        layer?.borderWidth = 1
        layer?.borderColor = theme.switcherBorder.cgColor
        layer?.shadowOpacity = 0.6
        layer?.shadowRadius = 30

        pill.wantsLayer = true
        pill.layer?.backgroundColor = theme.switcherTextActive.withAlphaComponent(pillWash).cgColor
        pill.layer?.cornerRadius = pillCorner
        addSubview(pill)

        glass.image = symbol(searchSymbol, size: fieldSize)
        glass.contentTintColor = theme.switcherText.withAlphaComponent(dimAlpha)
        pill.addSubview(glass)

        field.isBordered = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: fieldSize, weight: .regular)
        field.textColor = theme.switcherTextActive
        field.delegate = self
        pill.addSubview(field)
        pill.addSubview(badgeView)

        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        // Plain: the system's inset style pads the rows and floats the first one down.
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.addTableColumn(NSTableColumn(identifier: .init("p")))
        table.doubleAction = #selector(doubleClick)
        table.target = self
        // A click picks a row; the text field keeps the keyboard.
        table.refusesFirstResponder = true

        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.backgroundColor = .clear
        scroll.drawsBackground = false
        addSubview(scroll)

        rule.wantsLayer = true
        rule.layer?.backgroundColor = theme.switcherBorder.cgColor
        addSubview(rule)

        hintLabel.lineBreakMode = .byTruncatingTail
        addSubview(hintLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        window?.makeFirstResponder(field)
    }

    // The table shows `items`; the first line is picked, or nothing is.
    func setItems(_ items: [PickerItem], select: PickerSelect) {
        self.items = items
        lineRows = items.indices.filter { items[$0].isPickable }

        table.reloadData()
        table.deselectAll(nil)
        switch select {
        case .none:
            selectable = false
        case .first:
            selectable = true
            move(to: 0)
        case .line(let n):
            selectable = true
            move(to: n)
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height

        pill.frame = NSRect(x: cardInset, y: h - cardInset - pillHeight,
                            width: w - cardInset * 2, height: pillHeight)
        glass.frame = NSRect(x: cellPad - rowInset, y: (pillHeight - iconSize) / 2, width: iconSize, height: iconSize)

        let badgeWidth = badge.isEmpty ? 0 : badgeView.fitWidth
        let badgeX = pill.bounds.width - cellPad + badgePad - badgeWidth
        badgeView.isHidden = badge.isEmpty
        badgeView.frame = NSRect(x: badgeX, y: (pillHeight - badgeHeight) / 2,
                                 width: badgeWidth, height: badgeHeight)

        // Lines up with the rows' titles below (less the field's own padding).
        let fieldX = textLeft - rowInset - 2
        let fieldH: CGFloat = 22
        let fieldEnd = badge.isEmpty ? pill.bounds.width - cellPad : badgeX - cellPad / 2
        field.frame = NSRect(x: fieldX, y: (pillHeight - fieldH) / 2,
                             width: max(0, fieldEnd - fieldX), height: fieldH)

        rule.frame = NSRect(x: 0, y: hintsHeight, width: w, height: ruleHeight)
        hintLabel.sizeToFit()
        let hintH = hintLabel.frame.height
        hintLabel.frame = NSRect(x: cardInset + cellPad - rowInset, y: (hintsHeight - hintH) / 2,
                                 width: w - (cardInset + cellPad) * 2, height: hintH)

        let top = pill.frame.minY - cardInset / 2
        scroll.frame = NSRect(x: cardInset - rowInset, y: hintsHeight + ruleHeight,
                              width: w - (cardInset - rowInset) * 2,
                              height: max(0, top - hintsHeight - ruleHeight))
    }

    // MARK: Look

    private func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return image?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    }

    private func dimPlaceholder() {
        let color = GCTTheme.current.switcherText.withAlphaComponent(dimAlpha)
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: fieldSize, weight: .regular),
            .foregroundColor: color,
        ])
    }

    // "⏎ run    ↑↓ select    esc close": the key bright, what it does dim.
    private func showHints() {
        let theme = GCTTheme.current
        let font = NSFont.monospacedSystemFont(ofSize: subtitleSize, weight: .regular)
        let out = NSMutableAttributedString()

        for hint in hints {
            if out.length > 0 {
                out.append(NSAttributedString(string: hintGap, attributes: [.font: font]))
            }
            out.append(NSAttributedString(string: hint.key, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: subtitleSize, weight: .medium),
                .foregroundColor: theme.switcherText,
            ]))
            out.append(NSAttributedString(string: " " + hint.what, attributes: [
                .font: font,
                .foregroundColor: theme.switcherText.withAlphaComponent(faintAlpha + 0.1),
            ]))
        }

        hintLabel.attributedStringValue = out
        needsLayout = true
    }

    // MARK: Picking

    private func move(to line: Int) {
        guard lineRows.indices.contains(line) else { return }

        let row = lineRows[line]
        table.selectRowIndexes([row], byExtendingSelection: false)
        // The first line scrolls to the top so its section stays in view.
        table.scrollRowToVisible(line == 0 ? 0 : row)
    }

    private func step(_ delta: Int) {
        guard selectable, !lineRows.isEmpty else { return }

        let from = picked ?? -1
        move(to: min(lineRows.count - 1, max(0, from + delta)))
    }

    @objc private func enter() {
        onEnter?()
    }

    // Only a list that can be picked from runs on a double click.
    @objc private func doubleClick() {
        guard selectable else { return }

        enter()
    }

    // MARK: Field delegate

    func controlTextDidChange(_ obj: Notification) {
        onType?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            enter()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
            return true
        case #selector(NSResponder.moveDown(_:)):
            step(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            step(-1)
            return true
        default:
            return false
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .section, .host:
            return sectionHeight
        case .line(let line):
            return line.subtitle.isEmpty && line.strong.isEmpty ? lineHeight : lineHeightTall
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        selectable && items[row].isPickable
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PickerRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        switch items[row] {
        case .section(let title, let name):
            return PickerSectionCell(title: title, note: "", image: symbol(name, size: subtitleSize))
        case .host(let title, let name, let note):
            return PickerSectionCell(title: title, note: note, image: symbol(name, size: subtitleSize))
        case .line(let line):
            return PickerLineCell(line: line, image: symbol(line.symbol, size: titleSize))
        }
    }
}

private extension PickerItem {
    var isPickable: Bool {
        guard case .section = self else { return true }

        return false
    }
}

// The picked row: a wash and an accent bar down its left edge.
private final class PickerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let theme = GCTTheme.current
        let wash = bounds.insetBy(dx: rowInset, dy: 1)

        theme.switcherTextActive.withAlphaComponent(rowWash).setFill()
        NSBezierPath(roundedRect: wash, xRadius: rowCorner, yRadius: rowCorner).fill()

        let bar = NSRect(x: wash.minX, y: wash.minY + barInset,
                         width: barWidth, height: wash.height - barInset * 2)
        theme.accent.setFill()
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
}

// "▭ local": which machine the rows below belong to.
private final class PickerSectionCell: NSView {
    private let icon = NSImageView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")

    init(title: String, note text: String, image: NSImage?) {
        super.init(frame: .zero)
        let color = GCTTheme.current.switcherText.withAlphaComponent(dimAlpha)

        icon.image = image
        icon.contentTintColor = color
        addSubview(icon)

        label.stringValue = title
        label.font = .monospacedSystemFont(ofSize: subtitleSize, weight: .semibold)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        note.stringValue = text
        note.font = .monospacedSystemFont(ofSize: subtitleSize, weight: .regular)
        note.textColor = GCTTheme.current.switcherText.withAlphaComponent(faintAlpha + 0.1)
        note.lineBreakMode = .byTruncatingTail
        addSubview(note)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: cellPad, y: (h - iconSize) / 2, width: iconSize, height: iconSize)

        note.sizeToFit()
        let noteW = min(note.frame.width, bounds.width / 2)
        let noteX = bounds.width - cellPad - noteW
        note.frame = NSRect(x: noteX, y: (h - note.frame.height) / 2, width: noteW, height: note.frame.height)

        label.sizeToFit()
        label.frame = NSRect(x: textLeft, y: (h - label.frame.height) / 2,
                             width: max(0, noteX - textLeft - cellPad / 2), height: label.frame.height)
    }
}

// icon, title over subtitle, and something on the right.
private final class PickerLineCell: NSView {
    private let icon = NSImageView(frame: .zero)
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")

    init(line: PickerLine, image: NSImage?) {
        super.init(frame: .zero)
        let theme = GCTTheme.current

        icon.image = image
        icon.contentTintColor = theme.switcherText.withAlphaComponent(dimAlpha)
        addSubview(icon)

        title.stringValue = line.title
        title.font = .monospacedSystemFont(ofSize: titleSize, weight: .medium)
        title.textColor = theme.switcherTextActive
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)

        subtitle.attributedStringValue = subtitleText(line, theme)
        subtitle.lineBreakMode = .byTruncatingHead
        addSubview(subtitle)

        trailing.stringValue = line.trailing
        trailing.font = .monospacedSystemFont(ofSize: subtitleSize, weight: .regular)
        trailing.textColor = theme.switcherText.withAlphaComponent(faintAlpha + 0.1)
        trailing.lineBreakMode = .byTruncatingTail
        addSubview(trailing)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func subtitleText(_ line: PickerLine, _ theme: GCTTheme) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: subtitleSize, weight: .regular)
        let out = NSMutableAttributedString(string: line.subtitle, attributes: [
            .font: font,
            .foregroundColor: theme.switcherText.withAlphaComponent(dimAlpha),
        ])
        out.append(NSAttributedString(string: line.strong, attributes: [
            .font: font,
            .foregroundColor: theme.switcherText,
        ]))

        return out
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let hasSub = subtitle.attributedStringValue.length > 0

        icon.frame = NSRect(x: cellPad, y: (h - iconSize) / 2, width: iconSize, height: iconSize)

        trailing.sizeToFit()
        let trailW = min(trailing.frame.width, bounds.width / 3)
        let trailX = bounds.width - cellPad - trailW
        trailing.frame = NSRect(x: trailX, y: (h - trailing.frame.height) / 2,
                                width: trailW, height: trailing.frame.height)

        title.sizeToFit()
        subtitle.sizeToFit()
        let textW = max(0, trailX - textLeft - cellPad / 2)
        let titleH = title.frame.height
        let subH = hasSub ? subtitle.frame.height : 0
        // Centered as a block: the pair when there is a subtitle, the title alone otherwise.
        let top = (h + titleH + subH) / 2

        title.frame = NSRect(x: textLeft, y: top - titleH, width: textW, height: titleH)
        subtitle.frame = NSRect(x: textLeft, y: top - titleH - subH, width: textW, height: subH)
    }
}

// The session's name in a capsule, drawn by hand so the text sits dead center.
private final class PickerBadge: NSView {
    var text = "" {
        didSet { needsDisplay = true }
    }

    private var attrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: badgeSize, weight: .medium),
         .foregroundColor: GCTTheme.current.switcherText]
    }

    var fitWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: attrs).width) + badgePad * 2
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = GCTTheme.current
        theme.switcherTextActive.withAlphaComponent(pillWash).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2),
                                withAttributes: attrs)
    }
}
