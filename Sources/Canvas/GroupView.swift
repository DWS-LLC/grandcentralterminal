// Chrome of one terminal group: titlebar + colored border, mirroring
// PaneView so groups and windows read as one family. Frames are WORLD
// coordinates (subview of worldView, kept below every pane). Bounds
// derive from member union + padding (see GroupGeometry); hidden when
// the group has no visible members.
//
// Layout: the titlebar owns the top edge (like panes); the border shows
// on left/right/bottom via the inset background fill. Titlebar and
// border share the group color — solid titlebar, translucent body.

import AppKit
import Common

final class GroupView: NSView {
    // Match the panes so the family reads as one.
    static var titleBarHeight: CGFloat { PaneView.titleBarHeight }
    static let borderWidth: CGFloat = 4
    static let cornerRadius: CGFloat = 6

    let id: GroupID
    private let titlebar = NSView(frame: .zero)
    private let titleLabel = CATextLayer()

    private var baseColor: NSColor = .systemBlue
    private var groupName: String?

    init(id: GroupID) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = false

        titlebar.wantsLayer = true
        titlebar.autoresizingMask = [.width]
        // Square titlebar corners would poke past the rounded frame;
        // round just the top pair to match (same as PaneView).
        titlebar.layer?.cornerRadius = Self.cornerRadius
        titlebar.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        titlebar.layer?.masksToBounds = true
        addSubview(titlebar)

        titleLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        titleLabel.alignmentMode = .left
        titleLabel.truncationMode = .end
        titlebar.layer?.addSublayer(titleLabel)

        applyChrome()
        layoutChrome()
    }

    required init?(coder: NSCoder) { fatalError() }

    // Nil bounds = no visible members: hide.
    func update(bounds: NSRect?, name: String?, colorSpec: String?) {
        baseColor = GroupColor.resolve(colorSpec, key: name ?? id.uuid.uuidString)
        groupName = name
        guard let bounds, bounds.width > 0, bounds.height > 0 else {
            isHidden = true
            return
        }
        isHidden = false
        frame = bounds
        applyChrome()
        layoutChrome()
    }

    // Crisp title at the camera's zoom (see PaneView.syncTitleZoom).
    func syncTitleZoom(camera: CGFloat) {
        PaneView.setTextScale(titleLabel, camera: camera, window: window)
    }

    override func layout() {
        super.layout()
        layoutChrome()
    }

    private func layoutChrome() {
        let w = bounds.width
        let h = bounds.height
        // Titlebar spans the full width (it hides the top border); the
        // translucent body insets for the side/bottom border.
        titlebar.frame = NSRect(x: 0, y: h - Self.titleBarHeight,
                                width: w, height: Self.titleBarHeight)

        // Title text vertically centered, 8pt inset.
        let textH = min(Self.titleBarHeight - 6,
                        GCTTheme.current.titleFont.pointSize + 3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLabel.frame = CGRect(x: 8, y: (Self.titleBarHeight - textH) / 2,
                                  width: max(0, w - 16), height: textH)
        CATransaction.commit()
    }

    private func applyChrome() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Body: group color, translucent, inset by the border via the
        // frame fill; the visible side/bottom border is the layer edge.
        layer?.backgroundColor = baseColor.withAlphaComponent(0.16).cgColor
        layer?.borderColor = baseColor.withAlphaComponent(0.85).cgColor
        layer?.borderWidth = Self.borderWidth

        // Titlebar: solid group color, like a pane titlebar.
        titlebar.layer?.backgroundColor = baseColor.cgColor

        titleLabel.string = groupName ?? "Group"
        // Contrast text against the saturated titlebar.
        titleLabel.foregroundColor =
            (baseColor.gctLuminance > 0.55 ? NSColor.black : NSColor.white).cgColor
        titleLabel.font = GCTTheme.current.titleFont
        titleLabel.fontSize = GCTTheme.current.titleFont.pointSize
        CATransaction.commit()
    }

    func containsWorld(_ worldPoint: CGPoint) -> Bool {
        !isHidden && frame.contains(worldPoint)
    }
}

// Group colors: a hex, "palette:N" (ghostty ANSI N, follows the theme),
// or nil = auto: hash of the name onto the 16 ANSI colors.
enum GroupColor {
    static let autoSpec = "auto"
    static func resolve(_ spec: String?, key: String) -> NSColor {
        guard let spec else { return ansi(Int(key.gctHash) % GroupStyle.ansiCount) }
        if spec.hasPrefix(GroupStyle.palettePrefix) {
            let n = Int(spec.dropFirst(GroupStyle.palettePrefix.count)) ?? 0
            return ansi(n)
        }
        return NSColor(gctHex: spec) ?? ansi(Int(key.gctHash) % GroupStyle.ansiCount)
    }

    // Theme's ANSI color; the old hex palette when ghostty gave none.
    private static func ansi(_ n: Int) -> NSColor {
        let theme = GCTTheme.current.ansi
        if theme.indices.contains(n) { return theme[n] }
        let hex = GroupStyle.palette[n % GroupStyle.palette.count]
        return NSColor(gctHex: hex) ?? .systemBlue
    }

    // Picker: "Auto", a 2x8 swatch grid (normal | bright ANSI), "Custom…".
    // Picks send `pick` with "<scope>|<spec>" (just "<spec>" without a
    // scope): "auto" or "palette:N". `custom` gets the scope.
    static func menu(title: String, target: AnyObject?, pick: Selector,
                     custom: Selector, scope: String?) -> NSMenu {
        let prefix = scope.map { $0 + "|" } ?? ""
        let menu = NSMenu(title: title)

        let auto = NSMenuItem(title: "Auto (from name)", action: pick, keyEquivalent: "")
        auto.target = target
        auto.representedObject = prefix + autoSpec
        menu.addItem(auto)

        let grid = GroupColorGrid(colors: (0..<GroupStyle.ansiCount).map(ansi)) { [weak target] n in
            let item = NSMenuItem()
            item.representedObject = prefix + GroupStyle.palettePrefix + String(n)
            NSApp.sendAction(pick, to: target, from: item)
        }
        let gridItem = NSMenuItem()
        gridItem.view = grid
        menu.addItem(gridItem)

        menu.addItem(.separator())
        let other = NSMenuItem(title: "Custom…", action: custom, keyEquivalent: "")
        other.target = target
        other.representedObject = scope
        menu.addItem(other)
        return menu
    }
}

// Swatch grid for a menu item: column = n / rows, so ANSI 0-7 run down the
// left and the brights 8-15 down the right.
//
//   [0] [8]
//   [1] [9]
//   ...
//   [7] [15]
final class GroupColorGrid: NSView {
    private static let columns = 2
    private static let rows = 8
    private static let cell: CGFloat = 18
    private static let gap: CGFloat = 6
    private static let inset: CGFloat = 8
    private static let radius: CGFloat = 3

    private let colors: [NSColor]
    private let onPick: (Int) -> Void
    private var hovered: Int?

    init(colors: [NSColor], onPick: @escaping (Int) -> Void) {
        self.colors = colors
        self.onPick = onPick
        let w = Self.gridWidth + 2 * Self.inset
        let h = Self.gridHeight + 2 * Self.inset
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
        // The menu stretches the item to its width; the grid centers itself.
        autoresizingMask = [.width]
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited,
                                   .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static var gridWidth: CGFloat {
        CGFloat(columns) * cell + CGFloat(columns - 1) * gap
    }
    private static var gridHeight: CGFloat {
        CGFloat(rows) * cell + CGFloat(rows - 1) * gap
    }

    private func rect(_ n: Int) -> NSRect {
        let col = n / Self.rows
        let row = n % Self.rows
        let x0 = (bounds.width - Self.gridWidth) / 2
        return NSRect(x: x0 + CGFloat(col) * (Self.cell + Self.gap),
                      y: Self.inset + CGFloat(row) * (Self.cell + Self.gap),
                      width: Self.cell, height: Self.cell)
    }

    private func index(at p: NSPoint) -> Int? {
        colors.indices.first { rect($0).contains(p) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (n, color) in colors.enumerated() {
            let path = NSBezierPath(roundedRect: rect(n), xRadius: Self.radius,
                                    yRadius: Self.radius)
            color.setFill()
            path.fill()
            // Hairline keeps black/white swatches visible on any menu tint.
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            guard n == hovered else { continue }
            NSColor.labelColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let n = index(at: convert(event.locationInWindow, from: nil))
        guard n != hovered else { return }
        hovered = n
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let n = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onPick(n)
        // Close the whole menu tree, not just the submenu.
        var root = enclosingMenuItem?.menu
        while let up = root?.supermenu { root = up }
        root?.cancelTracking()
    }
}
