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
    static let titleBarHeight: CGFloat = 22
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
    func update(bounds: NSRect?, name: String?, colorHex: String?) {
        if let hex = colorHex, let c = NSColor(gctHex: hex) {
            baseColor = c
        }
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
