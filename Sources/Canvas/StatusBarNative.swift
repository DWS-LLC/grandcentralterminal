// Native status bar cells: the sessions and the window strip.
//
//   CanvasView ──StatusBarSource──► StatusBarView ──► StatusBarChipsCell
//   (sessions, panes)               (tokens, colors)   (draws + hit-tests)
//
// The bar never reaches into panes or sessions: it asks its source for
// plain values and says what was clicked. Tokens for [statusbar] components:
//
//   session    the attached session on screen
//   sessions   the other attached sessions, orange when one has news
//   windows    this session's panes, a chip each, with the titlebar's markers
//
//   ( local )  work  ● host                [ ✓ api ][ ◌ web ][ ▲ db ]          Sun 15 Nov

import AppKit
import Common

extension Notification.Name {
    /// Something the bar shows changed: a pane's chrome, a session.
    static let gctBarChanged = Notification.Name("gct.bar.changed")
}

// MARK: - What the bar asks the canvas

struct BarSession {
    let name: String
    let current: Bool
    let unread: Int
    // Its host color, as on its panes' titlebars; nil = the bar's own text.
    let color: NSColor?
}

struct BarWindow {
    let id: PaneID
    let name: String
    let state: ProgramState?
    let focused: Bool
    let notice: Bool
    let ended: Bool
    let offline: Bool
    let zoomed: Bool
    let floating: Bool
}

protocol StatusBarSource: AnyObject {
    func barSessions() -> [BarSession]
    func barWindows() -> [BarWindow]
    func barOpen(session: String)
    func barFocus(window: PaneID)
}

enum BarToken: String {
    case session, sessions, windows
}

enum BarTarget {
    case session(String)
    case window(PaneID)
}

// The titlebar's own markers, so a chip reads like the pane it stands for.
enum BarGlyph {
    static let blocked = "▲"
    static let error = "✕"
    static let done = "✓"
    static let working = "◌"
    static let ended = "✕"
    static let offline = "○"
    static let notice = "●"
    static let zoomed = "⤢"
    static let floating = "⬆"
}

// MARK: - Chips

struct BarChip {
    var glyph = ""
    var glyphColor: NSColor?
    // Plain markers after the glyph, in the text color (zoomed, floating).
    var badge = ""
    var text: String
    var textColor: NSColor?
    // Alpha of the capsule behind it; 0 = none.
    var fill: CGFloat = 0
    var bold = false
    var target: BarTarget
}

protocol StatusBarMeasured {
    func measuredWidth() -> CGFloat
}

extension StatusBarCellView: StatusBarMeasured {}

/// A row of capsules, drawn by hand: one view however many windows there
/// are. Too many for the room squeeze evenly, then the last ones drop off.
final class StatusBarChipsCell: NSView, StatusBarMeasured {
    let token: BarToken
    var onPick: ((BarTarget) -> Void)?
    var chips = [BarChip]() {
        didSet { needsDisplay = true }
    }

    private var hits = [(rect: NSRect, target: BarTarget)]()

    private static let padX: CGFloat = 8
    private static let padY: CGFloat = 4
    private static let glyphGap: CGFloat = 4
    private static let chipGap: CGFloat = 4
    private static let maxChip: CGFloat = 180
    private static let minChip: CGFloat = 44

    init(token: BarToken) {
        self.token = token
        super.init(frame: .zero)
        autoresizingMask = []
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        needsDisplay = true
    }

    func measuredWidth() -> CGFloat {
        guard !chips.isEmpty else { return 0 }

        return chips.map(naturalWidth).reduce(0, +) + gaps(chips.count)
    }

    private func gaps(_ count: Int) -> CGFloat {
        Self.chipGap * CGFloat(max(0, count - 1))
    }

    private func font(_ chip: BarChip) -> NSFont {
        let base = GCTTheme.current.statusbarFont
        guard chip.bold else { return base }

        return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    }

    private func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    private func glyphWidth(_ chip: BarChip) -> CGFloat {
        guard !chip.glyph.isEmpty else { return 0 }

        return textWidth(chip.glyph, font(chip)) + Self.glyphGap
    }

    private func badgeWidth(_ chip: BarChip) -> CGFloat {
        guard !chip.badge.isEmpty else { return 0 }

        return textWidth(chip.badge, font(chip)) + Self.glyphGap
    }

    private func naturalWidth(_ chip: BarChip) -> CGFloat {
        let w = Self.padX * 2 + glyphWidth(chip) + badgeWidth(chip)
            + textWidth(chip.text, font(chip))
        return min(Self.maxChip, w)
    }

    /// Chip widths for `room` points: natural, or squeezed to fit.
    private func fitted(_ room: CGFloat) -> [CGFloat] {
        let natural = chips.map(naturalWidth)
        let total = natural.reduce(0, +)
        let avail = room - gaps(chips.count)
        guard total > avail, total > 0 else { return natural }

        let k = max(0, avail) / total
        return natural.map { max(Self.minChip, floor($0 * k)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        hits = []
        guard !chips.isEmpty else { return }

        let h = bounds.height - Self.padY * 2
        var x: CGFloat = 0
        for (chip, w) in zip(chips, fitted(bounds.width)) {
            // Past the edge: this one and the rest don't fit.
            guard x + w <= bounds.width + 0.5 else { break }

            let rect = NSRect(x: x, y: Self.padY, width: w, height: h)
            draw(chip, in: rect)
            hits.append((rect, chip.target))
            x += w + Self.chipGap
        }
    }

    private func draw(_ chip: BarChip, in rect: NSRect) {
        let color = chip.textColor ?? GCTTheme.current.statusbarText
        if chip.fill > 0 {
            color.withAlphaComponent(chip.fill).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2,
                         yRadius: rect.height / 2).fill()
        }

        let font = font(chip)
        let lineH = ceil(font.ascender - font.descender)
        let y = rect.midY - lineH / 2
        var x = rect.minX + Self.padX
        if !chip.glyph.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: chip.glyphColor ?? color,
            ]
            (chip.glyph as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            x += glyphWidth(chip)
        }
        if !chip.badge.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            (chip.badge as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            x += badgeWidth(chip)
        }

        let style = NSMutableParagraphStyle()
        // Middle: for a path the tail is the part that tells panes apart.
        style.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ]
        let room = NSRect(x: x, y: y, width: max(0, rect.maxX - Self.padX - x), height: lineH)
        (chip.text as NSString).draw(in: room, withAttributes: attrs)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = hits.first(where: { $0.rect.contains(p) }) else { return }

        onPick?(hit.target)
    }
}

// MARK: - Source values -> chips

enum BarChips {
    private static let focusedFill: CGFloat = 0.22
    private static let idleFill: CGFloat = 0.08
    private static let idleText: CGFloat = 0.7

    static func make(_ token: BarToken, sessions: [BarSession],
                     windows: [BarWindow]) -> [BarChip] {
        switch token {
        case .session:
            return sessions.filter(\.current).map {
                BarChip(text: $0.name, textColor: $0.color, fill: focusedFill, bold: true,
                        target: .session($0.name))
            }
        case .sessions:
            return sessions.filter { !$0.current }.map(other)
        case .windows:
            return windows.map(window)
        }
    }

    // Quiet until something happened there; then orange, with the count.
    private static func other(_ s: BarSession) -> BarChip {
        guard s.unread > 0 else {
            return BarChip(text: s.name, textColor: s.color, target: .session(s.name))
        }

        return BarChip(glyph: BarGlyph.notice, text: "\(s.name) \(s.unread)",
                       textColor: .systemOrange, target: .session(s.name))
    }

    private static func window(_ w: BarWindow) -> BarChip {
        let (glyph, color) = marker(w)
        let text = GCTTheme.current.statusbarText
        let badge = (w.zoomed ? BarGlyph.zoomed : "") + (w.floating ? BarGlyph.floating : "")
        return BarChip(glyph: glyph, glyphColor: color, badge: badge, text: w.name,
                       textColor: w.focused ? nil : text.withAlphaComponent(idleText),
                       fill: w.focused ? focusedFill : idleFill, bold: w.focused,
                       target: .window(w.id))
    }

    // What the titlebar would badge this pane with, most urgent first.
    private static func marker(_ w: BarWindow) -> (String, NSColor?) {
        switch w.state {
        case .blocked: return (BarGlyph.blocked, .systemOrange)
        case .error: return (BarGlyph.error, .systemRed)
        case .done: return (BarGlyph.done, .systemGreen)
        case .working: return (BarGlyph.working, nil)
        case .idle, nil: break
        }
        if w.ended { return (BarGlyph.ended, nil) }
        if w.offline { return (BarGlyph.offline, nil) }
        if w.notice { return (BarGlyph.notice, GCTTheme.current.accent) }
        return ("", nil)
    }
}
