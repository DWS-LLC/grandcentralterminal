// A session with no windows is a blank canvas, and the title bar only names a
// host session. This says whose canvas it is, in the middle of it.
//
//        ┌──────────────────────────────┐
//        │            enterprise        │   the session
//        │   cmd+t to open a new pane   │   what to do about it
//        └──────────────────────────────┘
//
// Screen space, above the world and below the overlays; the mouse goes
// straight through it, so the canvas still pans and its menu still opens.

import AppKit

private let nameSize: CGFloat = 28
private let hintSize: CGFloat = 12
private let nameAlpha: CGFloat = 0.34
private let hintAlpha: CGFloat = 0.28
private let lineGap: CGFloat = 6
private let noWindows = "no windows"

final class EmptySessionView: NSView {
    private let name = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The canvas behind is the theme's, light or dark; read against it.
        let ink: NSColor = GCTTheme.isDark() ? .white : .black

        name.font = .monospacedSystemFont(ofSize: nameSize, weight: .semibold)
        name.textColor = ink.withAlphaComponent(nameAlpha)
        name.alignment = .center
        addSubview(name)

        hint.font = .monospacedSystemFont(ofSize: hintSize, weight: .regular)
        hint.textColor = ink.withAlphaComponent(hintAlpha)
        hint.alignment = .center
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError() }

    // `keys` is how a new pane is opened, if it is bound.
    func show(session: String, keys: String?) {
        name.stringValue = session
        hint.stringValue = keys.map { "\($0) to open a new pane" } ?? noWindows
        needsLayout = true
    }

    override func layout() {
        super.layout()
        name.sizeToFit()
        hint.sizeToFit()

        let block = name.frame.height + lineGap + hint.frame.height
        let top = (bounds.height + block) / 2
        name.frame = NSRect(x: 0, y: top - name.frame.height, width: bounds.width, height: name.frame.height)
        hint.frame = NSRect(x: 0, y: name.frame.minY - lineGap - hint.frame.height,
                            width: bounds.width, height: hint.frame.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
