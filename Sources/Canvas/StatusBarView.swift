// Screen-space overlay status bar: xbar-compatible components and gaps.
//
// Layout is one ordered cell list from `[statusbar] components`. Cells are
// plugin outputs or `gap` spacers; every gap absorbs an equal share of the
// leftover width, so component-gap-component-gap-component aligns
// left/center/right. The bar lives outside the camera transform (a direct
// CanvasView child, re-raised above the switcher), so panes slide under it
// and never collide with it.

import AppKit

// MARK: - On-disk plugin library

enum StatusBarLibrary {
    static var dir: URL {
        URL(fileURLWithPath: (GCTConfig.dir as NSString)
            .appendingPathComponent("statusbar"))
    }

    /// Create the folder on first launch, with a sample clock so an
    /// enabled bar shows something immediately. Never touches existing
    /// files: only a freshly created directory gets the sample.
    static func ensure() {
        let fm = FileManager.default
        let path = dir.path
        guard !fm.fileExists(atPath: path) else { return }
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        let sampleURL = dir.appendingPathComponent("clock.10s.sh")
        try? sample.write(to: sampleURL, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sampleURL.path)
    }

    /// Executable regular files, sorted, dotfiles skipped.
    static func files() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return items.filter { !$0.hasPrefix(".") }
            .map { dir.appendingPathComponent($0) }
            .filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                    && fm.isExecutableFile(atPath: $0.path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func signature(of files: [URL]) -> [String] {
        files.map(\.lastPathComponent)
    }

    private static let sample = """
        #!/usr/bin/env bash
        # <xbar.title>Clock</xbar.title>
        # <xbar.version>v1.0</xbar.version>
        # <xbar.author>GCT</xbar.author>
        # <xbar.desc>Sample status bar clock. Copy this file to make your own components.</xbar.desc>
        date +"%a %d %b  %H:%M"
        """
}

// MARK: - Click menus

enum StatusBarMenu {
    static func build(lines: [StatusBarLine], target: AnyObject?, action: Selector) -> NSMenu {
        let root = NSMenu()
        root.autoenablesItems = false
        var menus = [root]
        var lastItems: [NSMenuItem?] = [nil]
        for line in lines {
            let lvl = line.submenuLevel
            // Descend, hanging each submenu off the previous item.
            // A level jump with no parent just lands one deeper; no crash.
            while menus.count <= lvl {
                guard let parent = lastItems.last.flatMap({ $0 }) else { break }
                let sub = NSMenu()
                sub.autoenablesItems = false
                parent.submenu = sub
                parent.action = nil
                parent.target = nil
                menus.append(sub)
                lastItems.append(nil)
            }
            while menus.count > lvl + 1 {
                menus.removeLast()
                lastItems.removeLast()
            }
            guard let m = menus.last else { continue }
            if line.isSeparator {
                m.addItem(.separator())
                continue
            }
            var title = line.title
            if let max = line.params.length, title.count > max {
                title = String(title.prefix(max)) + "…"
            }
            let actionable = line.params.isActionable && !line.params.disabled
            let item = NSMenuItem(
                title: title.isEmpty ? "(empty)" : title,
                action: actionable ? action : nil, keyEquivalent: "")
            if actionable {
                item.target = target
                item.representedObject = line
            } else {
                item.isEnabled = !line.params.disabled
            }
            if title != line.title { item.toolTip = line.title }
            m.addItem(item)
            lastItems[lastItems.count - 1] = item
        }
        return root
    }
}

// MARK: - Component cell

final class StatusBarCellView: NSView {
    let plugin: StatusBarPlugin
    var onOutput: (() -> Void)?

    private let imageView = NSImageView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var cycler: Timer?
    private var cycle = 0
    private var current: StatusBarLine?
    private var displayTitle = ""
    private var hasImage = false

    init(plugin: StatusBarPlugin) {
        self.plugin = plugin
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = []
        imageView.imageScaling = .scaleProportionallyDown
        imageView.isHidden = true
        addSubview(imageView)
        label.lineBreakMode = .byClipping
        label.isSelectable = false
        label.backgroundColor = .clear
        label.isBordered = false
        addSubview(label)
        plugin.onUpdate = { [weak self] in self?.refreshed() }
        update()
        plugin.run()
        if let s = plugin.interval {
            timer = Timer.scheduledTimer(withTimeInterval: s, repeats: true) { [weak plugin] _ in
                plugin?.run()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func invalidate() {
        timer?.invalidate(); timer = nil
        cycler?.invalidate(); cycler = nil
        plugin.onUpdate = nil
    }

    func applyTheme() { update() }

    func measuredWidth() -> CGFloat {
        guard current != nil, !displayTitle.isEmpty || hasImage else { return 0 }
        let font = label.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let w = (displayTitle as NSString).size(withAttributes: [.font: font]).width
        // Match layoutCell's +4 pad so the cell is as wide as the label.
        return 6 + (hasImage ? 20 : 0) + ceil(w) + 4 + 6
    }

    private func refreshed() {
        cycle = 0
        update()
        onOutput?()
    }

    private func update() {
        let header = plugin.output.header
        if header.isEmpty {
            current = nil; displayTitle = ""; hasImage = false
            label.stringValue = ""
            imageView.image = nil; imageView.isHidden = true
            cycler?.invalidate(); cycler = nil
            return
        }
        cycle = cycle % header.count
        let line = header[cycle]
        current = line
        let theme = GCTTheme.current
        let size = line.params.fontSize ?? theme.statusbarFont.pointSize
        var font = theme.statusbarFont
        if let name = line.params.fontName, let f = NSFont(name: name, size: size) {
            font = f
        } else if size != font.pointSize, let f = NSFont(name: font.fontName, size: size) {
            font = f
        }
        label.font = font
        label.textColor = line.params.color ?? theme.statusbarText
        var title = line.title
        if let max = line.params.length, title.count > max {
            label.toolTip = title
            title = String(title.prefix(max)) + "…"
        } else {
            label.toolTip = nil
        }
        displayTitle = title
        label.stringValue = title
        if let img = line.params.templateImage ?? line.params.image {
            hasImage = true
            imageView.image = img
            imageView.isHidden = false
        } else {
            hasImage = false
            imageView.image = nil
            imageView.isHidden = true
        }
        // xbar cycles multi-line headers in the bar; ~2.5s per line.
        if header.count > 1, cycler == nil {
            cycler = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.cycle += 1
                self.update()
                self.onOutput?()
            }
        } else if header.count <= 1 {
            cycler?.invalidate()
            cycler = nil
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutCell()
    }

    private func layoutCell() {
        let h = bounds.height
        var x: CGFloat = 6
        if !imageView.isHidden {
            imageView.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
            x += 20
        }
        label.sizeToFit()
        var f = label.frame
        // sizeToFit on a label field can return a width 1-2pt short of
        // what the text actually needs (descenders, italic overhang,
        // "%" right bearing) — the trailing glyph then clips against the
        // cell edge, exactly the cut-off % in the report. Pad it.
        f.size.width = ceil(f.width) + 4
        f.origin = CGPoint(x: x, y: (h - f.height) / 2)
        label.frame = f
    }

    override func mouseDown(with event: NSEvent) {
        let menuLines = plugin.output.menu.filter { $0.params.dropdown }
        if menuLines.isEmpty {
            if let line = current, line.params.isActionable, !line.params.disabled {
                plugin.perform(line)
            }
            return
        }
        let menu = StatusBarMenu.build(
            lines: menuLines, target: self, action: #selector(menuAction(_:)))
        // popUp (not popUpContextMenu): the contextual path lets AppKit
        // append system items like AutoFill, which makes no sense here.
        // Anchor under the cell, centered on the click.
        let anchor = NSPoint(x: event.locationInWindow.x - menu.minimumWidth / 2,
                             y: event.locationInWindow.y)
        menu.popUp(positioning: nil, at: anchor, in: nil)
    }

    @objc private func menuAction(_ item: NSMenuItem) {
        guard let line = item.representedObject as? StatusBarLine else { return }
        plugin.perform(line)
    }

    // Subviews (label, image) would swallow clicks; route the whole cell
    // to mouseDown (menu / action).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
}

// MARK: - Expanding spacer

/// Zero-intrinsic-width cell. The bar splits leftover width equally among
/// gaps, so component-gap-component-gap-component lands left/center/right.
final class StatusBarGapView: NSView {}

// MARK: - The bar

final class StatusBarView: NSView {
    /// terminal=true handler, set by the canvas: (executable, args).
    /// Propagates to existing cells (init rebuilds before the canvas
    /// sets it — without this every plugin keeps a nil hook and
    /// terminal=true falls back to Apple's Terminal).
    var onTerminal: ((String, [String]) -> Void)? {
        didSet {
            for cell in cells {
                (cell as? StatusBarCellView)?.plugin.openInGCT = onTerminal
            }
        }
    }
    private var cells = [NSView]()
    private var watcher: Timer?
    private var signature = [String]()
    var barHeight: CGFloat { max(16, min(64, GCTConfig.current.statusbarHeight)) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Opaque gold must actually paint: layer-backed NSViews with
        // only backgroundColor sometimes never commit without a
        // needsDisplay + explicit opacity hint.
        layer?.isOpaque = true
        layer?.needsDisplayOnBoundsChange = true
        autoresizingMask = [.width, .minYMargin]
        rebuild()
        // No recompile, no restart: pick up added/removed plugins live.
        watcher = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.maybeRescan()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        let cfg = GCTConfig.current
        let base = GCTTheme.current.statusbarBackground
        let rgb = base.usingColorSpace(.sRGB) ?? base
        layer?.backgroundColor = rgb.withAlphaComponent(
            rgb.alphaComponent * CGFloat(cfg.statusbarOpacity)).cgColor
        for cell in cells { (cell as? StatusBarCellView)?.applyTheme() }
        positionCells()
    }

    func refresh() { positionCells() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionCells()
    }

    private func maybeRescan() {
        let files = StatusBarLibrary.files()
        guard StatusBarLibrary.signature(of: files) != signature else { return }
        rebuild()
    }

    private func rebuild() {
        for cell in cells {
            (cell as? StatusBarCellView)?.invalidate()
            cell.removeFromSuperview()
        }
        cells = []
        let files = StatusBarLibrary.files()
        signature = StatusBarLibrary.signature(of: files)
        for token in GCTConfig.current.statusbarComponents {
            if StatusBarCatalog.isGap(token) {
                cells.append(StatusBarGapView(frame: .zero))
                continue
            }
            // Unknown tokens are skipped, not fatal: a typo must never
            // take down the bar.
            guard let url = StatusBarCatalog.match(token: token, files: files) else { continue }
            let plugin = StatusBarPlugin(url: url)
            plugin.openInGCT = onTerminal
            let cell = StatusBarCellView(plugin: plugin)
            cell.onOutput = { [weak self] in self?.positionCells() }
            cells.append(cell)
        }
        for cell in cells { addSubview(cell) }
        applyTheme()
    }

    private func positionCells() {
        let spacing = GCTConfig.current.statusbarSpacing
        let inset: CGFloat = 8
        let widths = cells.map { ($0 as? StatusBarCellView)?.measuredWidth() ?? 0 }
        let gapCount = cells.filter { $0 is StatusBarGapView }.count
        let fixed = widths.reduce(0, +) + spacing * CGFloat(max(0, cells.count - 1))
        let avail = max(0, bounds.width - inset * 2)
        let gapW: CGFloat = gapCount > 0 ? max(0, (avail - fixed) / CGFloat(gapCount)) : 0
        var x = inset
        for (i, cell) in cells.enumerated() {
            let w = cell is StatusBarGapView ? gapW : widths[i]
            cell.frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
            x += w + spacing
        }
    }
}
