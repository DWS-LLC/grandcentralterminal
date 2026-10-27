// Menu row for a remote host that's down: its name, dimmed, with a circular
// retry button on the right.
//
//   ┌──────────────────────┐
//   │  bogus            ⟳  │
//   └──────────────────────┘

import AppKit

// Icon that lights up under the pointer: a round highlight, accent tint and a
// hand cursor, so it reads as clickable inside a menu. Draws itself, glyph
// dead center: NSButton's cell pads and offsets the image.
private final class RetryButton: NSButton {
    private static let hoverFill: CGFloat = 0.18
    private static let pressFill: CGFloat = 0.32
    private static let glyphPoints: CGFloat = 11

    private var hovering = false {
        didSet { needsDisplay = true }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        NSCursor.pop()
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            let fill = isHighlighted ? Self.pressFill : Self.hoverFill
            NSColor.labelColor.withAlphaComponent(fill).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }

        let tint: NSColor = hovering ? .controlAccentColor : .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: Self.glyphPoints, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let glyph = image?.withSymbolConfiguration(config) else { return }

        let size = glyph.size
        glyph.draw(in: NSRect(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height))
    }
}

final class RemoteRetryRow: NSView {
    private static let rowHeight: CGFloat = 22
    private static let minWidth: CGFloat = 170
    private static let inset: CGFloat = 14
    private static let buttonSize: CGFloat = 20
    private static let dimmed: CGFloat = 0.55

    private let onRetry: () -> Void

    init(name: String, color: NSColor?, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minWidth, height: Self.rowHeight))
        autoresizingMask = .width

        let label = NSTextField(labelWithAttributedString: NSAttributedString(
            string: "  \(name)",
            attributes: [.foregroundColor: (color ?? .labelColor).withAlphaComponent(Self.dimmed),
                         .font: NSFont.menuFont(ofSize: 0)]))
        label.frame = NSRect(x: Self.inset, y: 0,
                             width: Self.minWidth - Self.inset * 2 - Self.buttonSize,
                             height: Self.rowHeight - 4)
        label.frame.origin.y = (Self.rowHeight - label.frame.height) / 2
        label.autoresizingMask = .width
        addSubview(label)

        let image = NSImage(systemSymbolName: "arrow.clockwise",
                            accessibilityDescription: "Retry \(name)")
        let button = RetryButton(image: image ?? NSImage(), target: self, action: #selector(retry))
        button.isBordered = false
        button.toolTip = "Retry \(name) now"
        button.frame = NSRect(x: Self.minWidth - Self.inset - Self.buttonSize,
                              y: (Self.rowHeight - Self.buttonSize) / 2,
                              width: Self.buttonSize, height: Self.buttonSize)
        button.autoresizingMask = .minXMargin
        addSubview(button)
    }

    required init?(coder: NSCoder) { nil }

    // Dismiss the menu first, so the dial's result isn't racing a menu that
    // is still tracking.
    @objc private func retry() {
        enclosingMenuItem?.menu?.cancelTracking()
        onRetry()
    }
}
