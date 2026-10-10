// Window snapping: edge/center alignment within a radius, the
// full-canvas guide overlay, and the drag-to-create size label.
//
// SnapEngine is pure rect math in world coordinates (no config access)
// so the alignment rules are unit-testable; CanvasView converts the
// screen-space snap-radius, owns the overlay views, and calls in.
// Snapping is a drag-time nudge only: toggling it never re-lays-out
// existing panes, and collision resolution still runs after the snap
// (guides drop when the resolve pushes the rect back off the line).

import AppKit

enum SnapEngine {
    // Which anchors participate: edges (min/max), center (mid), or all.
    // Resize only ever uses edges (a moving edge to a foreign edge or
    // center); this filters MOVE anchors and guide emission.
    enum Mode {
        case all, center, edges
    }

    struct Result {
        var rect: NSRect
        var guidesX: [CGFloat]
        var guidesY: [CGFloat]
    }

    // Nearest value to `edge` in `targets` within `radius`, else nil.
    private static func nearest(_ edge: CGFloat, _ targets: [CGFloat],
                               _ radius: CGFloat) -> CGFloat? {
        var best: CGFloat?
        var bestDist = radius + 1
        for t in targets {
            let d = abs(t - edge)
            if d <= radius, d < bestDist { bestDist = d; best = t }
        }
        return best
    }

    // Move anchors for the mode: center keeps midX/midY only (edge
    // flashes drop out entirely, no mixed locks).
    private static func moveAnchors(_ r: NSRect, _ mode: Mode) -> (x: [CGFloat], y: [CGFloat]) {
        switch mode {
        case .center: return ([r.midX], [r.midY])
        case .edges: return ([r.minX, r.maxX], [r.minY, r.maxY])
        case .all: return ([r.minX, r.midX, r.maxX], [r.minY, r.midY, r.maxY])
        }
    }

    private static func xTargets(_ others: [NSRect], _ mode: Mode) -> [CGFloat] {
        switch mode {
        case .center: return others.map(\.midX)
        case .edges: return others.flatMap { [$0.minX, $0.maxX] }
        case .all: return others.flatMap { [$0.minX, $0.midX, $0.maxX] }
        }
    }

    private static func yTargets(_ others: [NSRect], _ mode: Mode) -> [CGFloat] {
        switch mode {
        case .center: return others.map(\.midY)
        case .edges: return others.flatMap { [$0.minY, $0.maxY] }
        case .all: return others.flatMap { [$0.minY, $0.midY, $0.maxY] }
        }
    }
    // Move: translate `rect` so one of its mode anchors lands on the
    // nearest foreign anchor, same per axis. At most one shift per axis
    // (the nearest).
    static func snapMove(_ rect: NSRect, others: [NSRect],
                         radius: CGFloat, mode: Mode = .edges) -> Result {
        guard radius > 0, !others.isEmpty else {
            return Result(rect: rect, guidesX: [], guidesY: [])
        }
        let xt = xTargets(others, mode), yt = yTargets(others, mode)
        var dx: CGFloat = 0, dy: CGFloat = 0
        var gx = [CGFloat](), gy = [CGFloat]()
        var bestX = radius + 1
        for m in moveAnchors(rect, mode).x {
            if let t = nearest(m, xt, radius), abs(t - m) < bestX {
                bestX = abs(t - m); dx = t - m
            }
        }
        var bestY = radius + 1
        for m in moveAnchors(rect, mode).y {
            if let t = nearest(m, yt, radius), abs(t - m) < bestY {
                bestY = abs(t - m); dy = t - m
            }
        }
        if bestX <= radius {
            // Every alignment the shift achieves: a flush tile lights
            // both shared edges, not just the nearest anchor.
            var seen = Set<CGFloat>()
            for m in moveAnchors(rect, mode).x {
                for t in xt where abs(m + dx - t) <= 0.5 {
                    if seen.insert(t).inserted { gx.append(t) }
                }
            }
        }
        if bestY <= radius {
            var seen = Set<CGFloat>()
            for m in moveAnchors(rect, mode).y {
                for t in yt where abs(m + dy - t) <= 0.5 {
                    if seen.insert(t).inserted { gy.append(t) }
                }
            }
        }
        var out = rect
        out.origin.x += dx; out.origin.y += dy
        return Result(rect: out, guidesX: gx, guidesY: gy)
    }

    // Resize: snap only the edges the zone moves. Opposite edges stay
    // put; snaps that would break the minimum size are skipped. `edges`
    // snaps the moving edge to foreign edges, `center` to foreign
    // centers, `all` to either.
    static func snapResize(_ rect: NSRect,
                           west: Bool, east: Bool,
                           south: Bool, north: Bool,
                           others: [NSRect], radius: CGFloat,
                           minSize: CGSize, mode: Mode = .edges) -> Result {
        guard radius > 0, !others.isEmpty else {
            return Result(rect: rect, guidesX: [], guidesY: [])
        }
        var out = rect
        var gx = [CGFloat](), gy = [CGFloat]()
        let xt = mode == .center ? xTargets(others, .center)
            : mode == .edges ? xTargets(others, .edges) : xTargets(others, .all)
        let yt = mode == .center ? yTargets(others, .center)
            : mode == .edges ? yTargets(others, .edges) : yTargets(others, .all)
        if east, !west {
            if let t = nearest(rect.maxX, xt, radius),
               t - rect.minX >= minSize.width {
                out.size.width = t - rect.minX; gx = [t]
            }
        } else if west, !east {
            if let t = nearest(rect.minX, xt, radius),
               rect.maxX - t >= minSize.width {
                out.origin.x = t
                out.size.width = rect.maxX - t
                gx = [t]
            }
        }
        if north, !south {
            if let t = nearest(rect.maxY, yt, radius),
               t - rect.minY >= minSize.height {
                out.size.height = t - rect.minY; gy = [t]
            }
        } else if south, !north {
            if let t = nearest(rect.minY, yt, radius),
               rect.maxY - t >= minSize.height {
                out.origin.y = t
                out.size.height = rect.maxY - t
                gy = [t]
            }
        }
        return Result(rect: out, guidesX: gx, guidesY: gy)
    }

    // Drag-to-create: snap the free corner to the nearest foreign
    // anchor per axis; the press anchor never moves.
    static func snapPoint(_ p: CGPoint, others: [NSRect],
                          radius: CGFloat, mode: Mode = .edges)
        -> (point: CGPoint, guideX: CGFloat?, guideY: CGFloat?) {
        guard radius > 0, !others.isEmpty else { return (p, nil, nil) }
        let sx = nearest(p.x, xTargets(others, mode), radius)
        let sy = nearest(p.y, yTargets(others, mode), radius)
        return (CGPoint(x: sx ?? p.x, y: sy ?? p.y), sx, sy)
    }
}

// Full-canvas guide lines in world coordinates (a subview of the
// camera-transformed world layer, so they pan/zoom with the panes).
// Pooled views, re-fronted on every show: group/pane refreshes
// re-stack subviews mid-drag and would otherwise bury the lines.
// Lines fade in/out (0.33s ease-in-out) so alignment changes read
// smoothly; content updates (same visible set, new frames) skip the
// fade and just move. A per-view generation invalidates stale
// completions: a re-shown line never gets hidden by an earlier
// fade-out finishing late.
final class SnapOverlay {
    private var pool = [NSView]()
    private weak var host: NSView?
    // Generation per pooled view: hide/show completions only land when
    // they still describe the view's latest state (fast drag scrubbing
    // fires show/hide faster than the 0.33s fade).
    private var generations = [ObjectIdentifier: Int]()

    init(host: NSView) { self.host = host }

    func show(x: [CGFloat], y: [CGFloat], span: NSRect,
              color: NSColor, scale: CGFloat) {
        let w = 1 / max(scale, 0.0001)
        var frames = [NSRect]()
        for gx in x {
            frames.append(NSRect(x: gx - w / 2, y: span.minY,
                                 width: w, height: span.height))
        }
        for gy in y {
            frames.append(NSRect(x: span.minX, y: gy - w / 2,
                                 width: span.width, height: w))
        }
        while pool.count < frames.count {
            let v = NSView(frame: .zero)
            v.wantsLayer = true
            v.alphaValue = 0
            pool.append(v)
        }
        for (i, v) in pool.enumerated() {
            guard i < frames.count else {
                guard !v.isHidden else { continue }
                fade(v, to: 0) { $0.isHidden = true }
                continue
            }
            let wasHidden = v.isHidden
            v.frame = frames[i]
            v.layer?.backgroundColor = color.cgColor
            v.isHidden = false
            host?.addSubview(v, positioned: .above, relativeTo: nil)
            if wasHidden { fade(v, to: 1) }
        }
    }

    func hide() {
        for v in pool where !v.isHidden { fade(v, to: 0) { $0.isHidden = true } }
    }

    private func fade(_ v: NSView, to: CGFloat,
                      done: ((NSView) -> Void)? = nil) {
        let key = ObjectIdentifier(v)
        let gen = (generations[key] ?? 0) + 1
        generations[key] = gen
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.33
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            v.animator().alphaValue = to
        } completionHandler: { [weak self] in
            guard self?.generations[ObjectIdentifier(v)] == gen else { return }
            done?(v)
        }
    }
}

// Screen-space "cols×rows" pill that follows the cursor during
// drag-to-create. Falls back to points before any surface exists to
// measure cell metrics from.
final class SnapSizeLabel {
    private let field = NSTextField(labelWithString: "")

    init(host: NSView) {
        field.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        field.textColor = .white
        field.alignment = .center
        field.wantsLayer = true
        field.layer?.backgroundColor =
            NSColor.black.withAlphaComponent(0.78).cgColor
        field.layer?.cornerRadius = 5
        field.isHidden = true
        host.addSubview(field)
    }

    func show(_ text: String, near p: CGPoint, in host: NSView) {
        field.stringValue = text
        field.sizeToFit()
        var f = field.frame
        // sizeToFit can return 1-2pt short; the padding absorbs it.
        f.size.width += 12; f.size.height += 6
        f.origin = CGPoint(x: p.x + 14, y: p.y - f.height - 10)
        f.origin.x = min(max(0, f.origin.x),
                         max(0, host.bounds.width - f.width))
        f.origin.y = min(max(0, f.origin.y),
                         max(0, host.bounds.height - f.height))
        field.frame = f
        field.isHidden = false
    }

    func hide() { field.isHidden = true }
}
