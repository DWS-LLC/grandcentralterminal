// The infinite canvas: all mouse/keyboard routing, camera, pane lifecycle.

import AppKit
import CGhostty
import Common

final class CanvasView: NSView {
    // MARK: State

    let worldView = NSView(frame: .zero)
    private(set) var camera = Camera()
    var panes = [PaneID: PaneView]()
    var zOrder = [PaneID]()
    private(set) var focusedID: PaneID?
    // Multi-select: staged pane ids (right-drag, shift+click, cmd+d)
    // that act as a unit for move/close/group WITHOUT being a daemon
    // group. Cleared on empty clicks, close, and explicit clear.
    var selectedIDs = Set<PaneID>()
    // Terminal groups: daemon-owned membership, local background views.
    var groupMetas = [GroupID: GroupMeta]()
    var groupViews = [GroupID: GroupView]()
    // Rubber-band selection of pane ids (world rect at press/drag).
    var selectionBand: (anchor: CGPoint, current: CGPoint)?
    var selectionView: NSView?
    // Right-click on a group background arms a possible group drag;
    // cleared on up (menu) or when the drag confirms.
    var pendingRightGroup: CGPoint?
    // Points per terminal cell, measured from any open surface (all panes
    // share the ghostty app config, so one measurement serves every
    // cols/rows <-> frame conversion). Nil until a surface exists.
    // Internal for keyboard-resize step; refreshCellMetrics keeps it fresh.
    var cellSize: CGSize?
    // A grid-sized pane created on an empty canvas got a provisional frame
    // (nothing to measure yet); corrected once its surface reports metrics.
    private var pendingGridFixup: (cols: Int, rows: Int)?
    // Directional split from a grouped pane joins it via CreatePane.joinGroup
    // (daemon places inside own bounds + admits; groupMeta broadcast
    // updates views). No client-side pending state.
    var conn: CanvasConn?
    private(set) var ghosttyApp: GhosttyApp?

    // Drag state machine.
    private enum Drag {
        case none
        case pan(start: CGPoint, offset0: CGPoint)
        case move(id: PaneID, grabDelta: CGPoint)
        case resize(id: PaneID, zone: PaneView.ResizeZone, rect0: NSRect)
        case surfaceClick(id: PaneID, button: ghostty_input_mouse_button_e)
        // Rubber-band: right-drag on empty space stages a multi-select
        // (no grouping until the user asks via keybind or menu).
        case select(anchor: CGPoint)
        // Multi-select move: every selected member at grab-time offsets.
        case multiMove(members: [PaneID], rects0: [PaneID: NSRect],
                       anchor: CGPoint)
        // Whole-group move: id plus the member offsets at grab time.
        case groupMove(id: GroupID, grabDelta: CGPoint,
                       members: [PaneID], rects0: [PaneID: NSRect])
        // Drag-to-create (opt-drag on empty space): the anchor stays put,
        // the free corner snaps; release opens a pane at the drawn rect.
        case create(anchor: CGPoint)
    }
    private var drag = Drag.none
    // Window snapping: guide overlay + drag-create state. Overlay views
    // are created lazily (first snap event) so startup stays identical.
    private var snapOverlay: SnapOverlay?
    private var snapSizeLabel: SnapSizeLabel?
    // Opt-drag on empty space arms a drag-to-create pane (confirmed as
    // .create once the pointer moves past the click threshold).
    private var pendingCreate: CGPoint?
    // Weak: removeFromSuperview drops the last strong reference, so the
    // property self-clears after dismissal.
    private weak var switcher: SwitcherView?
    var firstRunHandled = false
    // Screen-space overlay status bar (nil when disabled in config).
    var statusBar: StatusBarView?

    // IME composition state (NSTextInputClient below). markedText mirrors
    // the input context's preedit; keyTextAccumulator collects text the IME
    // commits while we're inside keyDown (nil when we're not in keyDown).
    private var markedText = NSMutableAttributedString()
    // Surface the preedit is drawn on — tracks the pane across focus moves
    // so preedit cleanup always targets the surface that shows it.
    private var markedHost: SurfaceHost?
    private var keyTextAccumulator: [String]?
    // Korean IMEs: a lone high surrogate delivered by insertText, waiting
    // for its trail half.
    private var pendingLeadSurrogate: LeadSurrogate?

    private var focusedHost: SurfaceHost? { focusedID.flatMap { panes[$0]?.host } }

    // Abandon any in-progress composition: clear marked text and the
    // preedit the surface is rendering. Focus is leaving the pane.
    private func dropComposition() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        if let host = markedHost, let surface = host.surfaceIfOpen() {
            ghostty_surface_preedit(surface, nil, 0)
        }
        markedHost = nil
    }

    // MARK: Setup

    func setup() {
        ghosttyApp = GhosttyApp(delegate: self)
        worldView.wantsLayer = true
        addSubview(worldView)
        worldView.frame = bounds
        worldView.autoresizingMask = [.width, .height]
        window?.acceptsMouseMovedEvents = true
        setupStatusBar()

        conn = CanvasConn(sockPath: CanvasPaths.sockPath)
        conn?.delegate = self
        conn?.start()
        // Window state drives occlusion: miniaturize / un-hide changes
        // which renderers need to run. Camera moves call refresh via
        // applyCamera; creation refreshes in makePaneView.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: nil,
            queue: .main) { [weak self] _ in self?.refreshOcclusion() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: nil,
            queue: .main) { [weak self] _ in self?.refreshOcclusion() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification, object: nil,
            queue: .main) { [weak self] _ in self?.refreshOcclusion() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didUnhideNotification, object: nil,
            queue: .main) { [weak self] _ in self?.refreshOcclusion() }
    }

    // Recompute the theme from config + ghostty and apply it everywhere.
    func applyTheme() {
        GCTTheme.refresh(ghosttyBackground: ghosttyApp?.background)
        let bg = GCTTheme.current.canvasBackground
        window?.backgroundColor = bg
        // Alpha < 1 needs a non-opaque window or AppKit ignores it.
        window?.isOpaque = bg.alphaComponent >= 1
        // Border width is theme state: applyChrome relayouts before
        // repainting, then the surface follows the inset terminal frame.
        for pane in panes.values { pane.applyChrome(); pane.syncSurfaceSize() }
        statusBar?.applyTheme()
        layoutStatusBar()
    }

    // appearance = "system": light/dark follows macOS, so re-resolve on change.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override var acceptsFirstResponder: Bool { true }

    // Manual routing: the world layer transform means AppKit hit-testing
    // is meaningless for panes; we take every event ourselves. Screen-space
    // overlays (the switcher) still get normal hit-testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        // Screen-space overlays get normal hit-testing: the bar first
        // (it sits on its own topmost layer), then the switcher.
        if let bar = statusBar, bar.superview != nil, bar.frame.contains(p) {
            return super.hitTest(point)
        }
        if let switcher, switcher.window != nil,
           switcher.frame.contains(p) {
            return switcher
        }
        return self
    }

    // MARK: Status bar

    private func setupStatusBar() {
        guard GCTConfig.current.statusbarEnabled else { return }
        StatusBarLibrary.ensure()
        let bar = StatusBarView()
        // terminal=true rows open in a new GCT pane, never Apple's
        // Terminal: same placement/focus/camera as cmd+t.
        bar.onTerminal = { [weak self] exe, args in
            self?.openCommandInPane(exe, args: args)
        }
        statusBar = bar
        addSubview(bar)
        layoutStatusBar()
        bar.applyTheme()
    }

    /// Run an executable+args in a new pane. Falls back to a login shell
    /// when the command line is empty.
    func openCommandInPane(_ exe: String, args: [String]) {
        let cwd = focusedID.flatMap { panes[$0]?.meta.cwd }
        let r = newPaneRect(direction: GCTConfig.current.newWindowDirection)
        var cmd = ([exe] + args).map {
            $0.contains(" ") ? "\"\($0)\"" : $0
        }.joined(separator: " ")
        if cmd.trimmingCharacters(in: .whitespaces).isEmpty {
            cmd = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        }
        conn?.createPane(CreatePane(
            rect: Rect(x: r.minX, y: r.minY, w: r.width, h: r.height),
            cwd: cwd,
            name: exe.split(separator: "/").last.map(String.init),
            command: cmd,
            allowOverlap: GCTConfig.current.allowWindowOverlap))
    }

    private func layoutStatusBar() {
        guard let bar = statusBar, bar.superview != nil else { return }
        let h = bar.barHeight
        // Window is already constrained to the visible frame, so top of
        // window == below the menubar. No offset math here.
        let y: CGFloat
        switch GCTConfig.current.statusbarPosition {
        case .top: y = bounds.height - h
        case .bottom: y = 0
        }
        bar.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
        bar.refresh()
    }

    override func layout() {
        super.layout()
        layoutStatusBar()
    }

    // MARK: Window snapping (helpers; drag call sites below)

    // Config snapping-type -> engine anchors.
    private var snapMode: SnapEngine.Mode {
        switch GCTConfig.current.snappingType {
        case .all: return .all
        case .center: return .center
        case .edges: return .edges
        }
    }

    // Snap scope. Three rules, one place:
    // - a pane IN a group (even solo) snaps only to its siblings'
    //   frames: nothing outside the group, not even its own border
    //   (a solo member has no targets and never snaps);
    // - a whole-group drag snaps the BORDER union to ungrouped panes
    //   and foreign GROUP BORDERS (never into another group's members —
    //   those ride inside their own border);
    // - an ungrouped pane snaps to ungrouped sibling frames and foreign
    //   group borders (never into grouped members).
    // Group borders still collide (Overlap) — this only scopes the
    // magnetic targets + guides.

    // Foreign targets for moving `moving`: sibling frames when grouped
    // (empty when solo), else ungrouped frames + foreign group borders.
    private func snapTargetsForPane(moving: PaneID) -> [NSRect] {
        if let own = groupOf(moving) {
            let siblings = groupMetas[own]?.members ?? []
            return siblings.compactMap { m in
                m == moving ? nil : panes[m]?.frame
            }
        }
        return snapTargetsForUngrouped(excluding: Set([moving]))
    }

    // Foreign targets for outsiders (ungrouped panes, drag-to-create):
    // ungrouped frames + every foreign group border.
    private func snapTargetsForUngrouped(excluding: Set<PaneID>) -> [NSRect] {
        var out = [NSRect]()
        let grouped = Set(groupMetas.values.flatMap(\.members))
        for (id, pane) in panes
            where !excluding.contains(id) && !grouped.contains(id) {
            out.append(pane.frame)
        }
        for (_, b) in GroupLayout.bounds(groups: groupMetas, panes: paneRects()) {
            out.append(NSRectOverlap.to(b))
        }
        return out
    }

    // Foreign targets for a whole-group/block drag of `ids`: ungrouped
    // frames (never grouped members) + foreign group borders (never
    // the dragged groups' own).
    private func snapTargetsForBlock(ids: Set<PaneID>) -> [NSRect] {
        var out = [NSRect]()
        let grouped = Set(groupMetas.values.flatMap(\.members))
        for (id, pane) in panes
            where !ids.contains(id) && !grouped.contains(id) {
            out.append(pane.frame)
        }
        for (gid, b) in GroupLayout.bounds(groups: groupMetas, panes: paneRects()) {
            if let gm = groupMetas[gid]?.members,
               gm.contains(where: { ids.contains($0) }) { continue }
            out.append(NSRectOverlap.to(b))
        }
        return out
    }

    // Snap the moving rect against every same-scope pane anchor, then
    // redraw guides. Returns the (maybe shifted) rect. Runs AFTER
    // the collision resolve: snapping is a drag-time nudge, never a pass
    // through other windows, and over-eager snaps that the resolve
    // pushed back drop their guides (the rect no longer sits on them).
    private func snapMovedRect(_ rect: NSRect,
                               moving: PaneID) -> NSRect {
        guard GCTConfig.current.snapping else { hideSnapGuides(); return rect }
        let radius = camera.screenToWorldDistance(GCTConfig.current.snapRadius)
        // Grouped (even solo): siblings only — empty means no snap, no
        // guides. Ungrouped: ungrouped frames + group borders. Never
        // into grouped members from outside.
        let others = snapTargetsForPane(moving: moving)
        let r = SnapEngine.snapMove(rect, others: others, radius: radius,
                                    mode: snapMode)
        showSnapGuides(x: r.guidesX, y: r.guidesY, near: r.rect)
        return r.rect
    }

    // Whole-group/block drag: snap the BORDER UNION (post-resolve
    // member frames -> padded bounds, mirroring GroupGeometry) to
    // ungrouped frames + foreign group borders. Members ride the
    // border delta rigidly. Guides sit on the border's snapped edges.
    // Callers resolve first, then pass the post-resolve frames here.
    private func snapBlockDelta(members: [PaneID: NSRect],
                                ids: Set<PaneID>) -> CGPoint {
        guard GCTConfig.current.snapping else { hideSnapGuides(); return .zero }
        guard let union = groupBoundsFrom(members) else { return .zero }
        let radius = camera.screenToWorldDistance(GCTConfig.current.snapRadius)
        // Never into another group's members: ungrouped frames +
        // foreign borders only.
        let others = snapTargetsForBlock(ids: ids)
        let r = SnapEngine.snapMove(union, others: others, radius: radius,
                                    mode: snapMode)
        showSnapGuides(x: r.guidesX, y: r.guidesY, near: r.rect)
        return CGPoint(x: r.rect.minX - union.minX, y: r.rect.minY - union.minY)
    }

    // Resize-side snap: only the zone's moving edges pull. Runs BEFORE
    // the collision clamp so growing into a snapped neighbor still holds
    // at the shared edge instead of punching through.
    private func snapResizedRect(_ rect: NSRect, rect0: NSRect,
                                 zone: PaneView.ResizeZone,
                                 moving: PaneID) -> (rect: NSRect,
                                                     guidesX: [CGFloat],
                                                     guidesY: [CGFloat]) {
        guard GCTConfig.current.snapping else { hideSnapGuides(); return (rect, [], []) }
        let radius = camera.screenToWorldDistance(GCTConfig.current.snapRadius)
        // Same scope as moves: siblings when grouped (empty when solo:
        // no snap, no guides), else ungrouped frames + foreign borders.
        let others = snapTargetsForPane(moving: moving)
        let r = SnapEngine.snapResize(
            rect, west: zone.resizesW, east: zone.resizesE,
            south: zone.resizesS, north: zone.resizesN,
            others: others, radius: radius,
            minSize: CGSize(width: 160, height: 120), mode: snapMode)
        showSnapGuides(x: r.guidesX, y: r.guidesY, near: r.rect)
        return (r.rect, r.guidesX, r.guidesY)
    }

    // Guide lines that survive the collision resolve stay lit; others
    // (an over-eager snap the blocker pushed back) drop.
    private func keepSnapGuides(x: [CGFloat], y: [CGFloat], on rect: NSRect) {
        let kx = x.filter { gx in
            [rect.minX, rect.midX, rect.maxX].contains { abs($0 - gx) <= 0.5 }
        }
        let ky = y.filter { gy in
            [rect.minY, rect.midY, rect.maxY].contains { abs($0 - gy) <= 0.5 }
        }
        if kx.isEmpty, ky.isEmpty { hideSnapGuides() } else { showSnapGuides(x: kx, y: ky, near: rect) }
    }

    // Paint world-space guides, or clear when nothing aligned. Color
    // from snap-guide-color ("none"/show-snap-guides=false = no paint,
    // only the snap still applies). "default" is translucent silver.
    // Span covers every pane + the rect.
    private func showSnapGuides(x: [CGFloat], y: [CGFloat], near rect: NSRect) {
        guard !x.isEmpty || !y.isEmpty else { hideSnapGuides(); return }
        guard GCTConfig.current.showSnapGuides else { return }
        let spec = GCTConfig.current.snapGuideColor ?? "default"
        guard spec.lowercased() != "none" else { return }
        let color = NSColor(gctHex: spec)
            ?? NSColor(white: 0.75, alpha: 0.55)
        showSnapGuidesRaw(x: x, y: y, near: rect, color: color)
    }

    private func showSnapGuidesRaw(x: [CGFloat], y: [CGFloat], near rect: NSRect,
                                   color: NSColor) {
        if snapOverlay == nil { snapOverlay = SnapOverlay(host: worldView) }
        var span = rect
        for pane in panes.values { span = span.union(pane.frame) }
        let m: CGFloat = 4000
        span = span.insetBy(dx: -m, dy: -m)
        snapOverlay?.show(x: x, y: y, span: span,
                          color: color, scale: camera.scale)
    }

    private func hideSnapGuides() { snapOverlay?.hide() }

    // cols×rows under the pointer for the drag-create rect. Mirrors
    // frameForGrid (titlebar + border included) so the pill reads the
    // terminal size the pane will actually open at.
    private func gridSizeText(for rect: NSRect) -> String {
        guard let cell = cellSize, cell.width > 0, cell.height > 0 else {
            return "\(Int(rect.width))×\(Int(rect.height))pt"
        }
        let bw = GCTTheme.current.borderWidth
        let cols = max(1, Int(round((rect.width - bw * 2) / cell.width)))
        let rows = max(1, Int(round(
            (rect.height - PaneView.titleBarHeight - bw) / cell.height)))
        return "\(cols)×\(rows)"
    }
    // Session-only flip (never moves panes). Guides clear when turning
    // off mid-drag; turning on just arms future drags.
    func toggleSnapping() {
        GCTConfig.current.snapping.toggle()
        if !GCTConfig.current.snapping { hideSnapGuides() }
    }

    private var isIdleDrag: Bool {
        if case .none = drag { return true }
        return false
    }
    // Drag-to-create band: reuse the blue selection styling, but draw
    // the SNAPPED rect so the box matches the pane that will open. The
    // size pill reads cols×rows from the same box.
    private func showCreateBand(at world: CGPoint) {
        guard case .create(let anchor) = drag else { return }
        let drawn = snappedCreateRect(anchor: anchor, free: world)
        selectionBand = (anchor: CGPoint(x: drawn.rect.minX, y: drawn.rect.minY),
                         current: CGPoint(x: drawn.rect.maxX, y: drawn.rect.maxY))
        showSelectionBand()
        if snapSizeLabel == nil { snapSizeLabel = SnapSizeLabel(host: self) }
        snapSizeLabel?.show(gridSizeText(for: drawn.rect),
                            near: convert(NSEvent.mouseLocation, from: nil),
                            in: self)
        if drawn.guideX == nil, drawn.guideY == nil {
            hideSnapGuides()
        } else {
            showSnapGuides(x: drawn.guideX.map { [$0] } ?? [],
                           y: drawn.guideY.map { [$0] } ?? [],
                           near: drawn.rect)
        }
    }

    // Free corner snapped to nearby edges (when snapping is on); press
    // anchor fixed. Enforces the 160×120 minimum so the pill and the
    // created pane agree.
    private func snappedCreateRect(anchor: CGPoint, free: CGPoint)
        -> (rect: NSRect, guideX: CGFloat?, guideY: CGFloat?) {
        var corner = free
        var gx: CGFloat?; var gy: CGFloat?
        if GCTConfig.current.snapping {
            // A drawn pane opens ungrouped: ungrouped frames + group
            // borders (never into grouped members).
            let others = snapTargetsForUngrouped(excluding: [])
            let s = SnapEngine.snapPoint(
                free, others: others,
                radius: camera.screenToWorldDistance(GCTConfig.current.snapRadius),
                mode: snapMode)
            corner = s.point; gx = s.guideX; gy = s.guideY
        }
        var rect = NSRect(
            x: min(anchor.x, corner.x), y: min(anchor.y, corner.y),
            width: abs(corner.x - anchor.x), height: abs(corner.y - anchor.y))
        if rect.width < 160 {
            rect.origin.x = corner.x >= anchor.x ? anchor.x : anchor.x - 160
            rect.size.width = 160
            if corner.x >= anchor.x, gx != nil,
               abs(anchor.x + 160 - gx!) > 0.5 { gx = nil }
            if corner.x < anchor.x, gx != nil,
               abs(anchor.x - 160 - gx!) > 0.5 { gx = nil }
        }
        if rect.height < 120 {
            rect.origin.y = corner.y >= anchor.y ? anchor.y : anchor.y - 120
            rect.size.height = 120
            if corner.y >= anchor.y, gy != nil,
               abs(anchor.y + 120 - gy!) > 0.5 { gy = nil }
            if corner.y < anchor.y, gy != nil,
               abs(anchor.y - 120 - gy!) > 0.5 { gy = nil }
        }
        return (rect, gx, gy)
    }

    private func applyCamera() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        worldView.layer?.sublayerTransform = camera.transform()
        CATransaction.commit()
        refreshOcclusion()
    }

    // Renderer pause per pane: ghostty stops a surface's DisplayLink
    // while occluded (VT keeps flowing, presents stop). Sources:
    // camera frustum (off-screen panes), miniaturized/hidden window.
    // Cheap rect test, idempotent inside ghostty (visible==visible
    // short-circuits). Called on every camera commit + window state
    // change; panes created visible by default (makePaneView refreshes).
    func refreshOcclusion() {
        assert(Thread.isMainThread)
        // Ordered-out (doom-hidden) or miniaturized: no surface can
        // present, so pause every DisplayLink. VT keeps flowing; the
        // ring replays on show. Without this, doom-hidden burns GPU on
        // a window nobody can see.
        let windowVisible = (window?.isVisible ?? false) && !(window?.isMiniaturized ?? false)
        let viewBounds = bounds
        for pane in panes.values {
            guard let host = pane.host else { continue }
            // World frame -> screen: camera transform, then view bounds.
            let sp = camera.worldToScreen(pane.frame.origin)
            let ss = pane.frame.size.applying(
                CGAffineTransform(scaleX: camera.scale, y: camera.scale))
            let screenRect = NSRect(origin: sp, size: ss)
            let visible = windowVisible && viewBounds.intersects(screenRect)
            host.setOcclusion(visible)
        }
    }

    private func viewPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func worldPoint(_ event: NSEvent) -> CGPoint {
        camera.screenToWorld(viewPoint(event))
    }

    // MARK: Pane lookup helpers

    private func topPane(at worldPoint: CGPoint, grab: CGFloat = 0) -> PaneView? {
        for id in zOrder.reversed() {
            if let pane = panes[id], pane.containsWorld(worldPoint, grab: grab) { return pane }
        }
        return nil
    }

    private func bringToFront(_ id: PaneID) {
        guard let pane = panes[id] else { return }
        zOrder.removeAll { $0 == id }
        zOrder.append(id)
        pane.removeFromSuperview()
        worldView.addSubview(pane)
        restackFloating()
    }

    // Live floating ids from pane metas.
    func floatingPanes() -> Set<PaneID> {
        Set(panes.values.lazy.filter(\.meta.floating).map(\.id))
    }

    // Floating panes stack above every tiled pane (order within each
    // layer follows zOrder). Called after focus/z changes and meta
    // updates.
    func restackFloating() {
        for id in zOrder {
            guard let pane = panes[id], !pane.meta.floating else { continue }
            pane.removeFromSuperview()
            worldView.addSubview(pane)
        }
        for id in zOrder {
            guard let pane = panes[id], pane.meta.floating else { continue }
            pane.removeFromSuperview()
            worldView.addSubview(pane)
        }
    }

    // Toggle float on the focused pane. Daemon owns the flag (persisted
    // + broadcast via paneMeta); restack locally for instant feedback.
    func toggleFloating() {
        guard let id = focusedID, let pane = panes[id] else { return }
        let next = !pane.meta.floating
        var meta = pane.meta
        meta.floating = next
        pane.update(meta: meta)
        restackFloating()
        conn?.setFloating(SetFloating(id: id, floating: next,
            allowOverlap: GCTConfig.current.allowWindowOverlap))
    }
    func focusPane(_ id: PaneID) {
        focusPane(id, raise: true)
    }

    // raise=false: focus without restacking. Hover focus must not churn
    // z-order on every mouse sweep; click/keyboard focus still raises.
    func focusPane(_ id: PaneID, raise: Bool) {
        guard panes[id] != nil else { return }
        if let old = focusedID, old != id {
            panes[old]?.host?.setFocus(false)
            panes[old]?.isFocused = false
            dropComposition()
        }
        focusedID = id
        if let pane = panes[id] {
            pane.isFocused = true
            pane.host?.setFocus(true)
            window?.makeFirstResponder(self)
        }
        if raise { bringToFront(id) }
    }

    // MARK: Mouse
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let world = worldPoint(event)
        if let pane = topPane(at: world, grab: camera.screenToWorldDistance(5)) {
            // Shift+click on chrome (titlebar/border, NOT the terminal
            // surface) toggles multi-select; terminal-area shift+click
            // keeps extending text selection. Resize zones still resize.
            if event.modifierFlags.contains(.shift) && !pane.surfaceContains(world),
               pane.resizeZone(at: world, screenTolerance: camera.screenToWorldDistance(5)) == nil {
                focusPane(pane.id)
                toggleSelected(pane.id)
                drag = .none
                return
            }
            focusPane(pane.id)
            // Plain click on an unselected pane drops the staging (the
            // titlebar drag path above keeps it for block moves).
            if !event.modifierFlags.contains(.shift), !selectedIDs.contains(pane.id) {
                clearSelection()
            }
            if let zone = pane.resizeZone(at: world,
                                          screenTolerance: camera.screenToWorldDistance(5)) {
                drag = .resize(id: pane.id, zone: zone, rect0: pane.frame)
                return
            }
            if pane.isInTitlebar(world) {
                // Dragging a selected pane's titlebar moves the whole
                // selection as a rigid block.
                if selectedIDs.contains(pane.id), selectedIDs.count >= 2 {
                    var rects = [PaneID: NSRect]()
                    for m in selectedIDs {
                        if let p = panes[m] { rects[m] = p.frame }
                    }
                    drag = .multiMove(members: Array(rects.keys), rects0: rects,
                                      anchor: world)
                    return
                }
                drag = .move(id: pane.id,
                             grabDelta: CGPoint(x: world.x - pane.frame.minX,
                                                y: world.y - pane.frame.minY))
                return
            }
            // Terminal surface click.
            let local = pane.surfacePoint(at: world)
            let mods = GhosttyMods(event.modifierFlags)
            let button: ghostty_input_mouse_button_e =
                switch event.buttonNumber {
                case 1: GHOSTTY_MOUSE_RIGHT
                case 2: GHOSTTY_MOUSE_MIDDLE
                default: GHOSTTY_MOUSE_LEFT
                }
            pane.host?.mousePos(x: local.x, y: local.y, mods: mods)
            pane.host?.mouseButton(GHOSTTY_MOUSE_PRESS, button, mods)
            drag = .surfaceClick(id: pane.id, button: button)
            return
        }

        // Group background (not on a pane): drag moves the whole group —
        // even with opt held (opt-drag creates panes only on EMPTY space).
        if let g = topGroup(at: world), let b = groupBounds(g.id) {
            var rects = [PaneID: NSRect]()
            for m in groupMetas[g.id]?.members ?? [] {
                if let p = panes[m] { rects[m] = p.frame }
            }
            drag = .groupMove(id: g.id,
                              grabDelta: CGPoint(x: world.x - b.minX,
                                                 y: world.y - b.minY),
                              members: Array(rects.keys), rects0: rects)
            return
        }

        // Opt-drag on empty space draws a new pane (snapped free corner,
        // live cols×rows pill); plain drag pans. Armed here, confirmed
        // as .create once the pointer moves past the click threshold.
        if event.modifierFlags.contains(.option) {
            pendingCreate = world
            if !event.modifierFlags.contains(.shift) { clearSelection() }
            return
        }
        // Plain drag on empty space pans the camera. (Rubber-band grouping
        // is on the right button; group menus too — see rightMouseDown.)
        // A plain left press (no shift) clears the multi-select; the drag
        // still pans.
        if !event.modifierFlags.contains(.shift) { clearSelection() }
        drag = .pan(start: viewPoint(event), offset0: camera.offset)
    }

    override func mouseDragged(with event: NSEvent) {
        // Opt-drag armed on empty space: past the click threshold it
        // becomes a drag-to-create (world-space rect + size pill).
        if let anchor = pendingCreate, isIdleDrag {
            let world = worldPoint(event)
            let tol = camera.screenToWorldDistance(6)
            if abs(world.x - anchor.x) > tol || abs(world.y - anchor.y) > tol {
                drag = .create(anchor: anchor)
                selectionBand = (anchor: anchor, current: world)
                showCreateBand(at: world)
            }
            return
        }
        switch drag {
        case .pan(let start, let offset0):
            let p = viewPoint(event)
            camera.offset = CGPoint(x: offset0.x + (p.x - start.x),
                                    y: offset0.y + (p.y - start.y))
            applyCamera()
        case .select(let anchor):
            selectionBand = (anchor: anchor, current: worldPoint(event))
            showSelectionBand()
        case .create:
            showCreateBand(at: worldPoint(event))
        case .groupMove(let id, let grabDelta, let members, let rects0):
            let world = worldPoint(event)
            guard let b0 = groupBoundsFrom(rects0) else { return }
            let want = CGPoint(x: world.x - grabDelta.x, y: world.y - grabDelta.y)
            let dx = want.x - b0.minX, dy = want.y - b0.minY
            // Member targets from grab-time layout (no drift).
            var targets = [PaneID: Rect]()
            for m in members {
                guard let r0 = rects0[m] else { continue }
                targets[m] = Rect(x: Double(r0.minX + dx),
                                  y: Double(r0.minY + dy),
                                  w: Double(r0.width), h: Double(r0.height))
            }
            guard !targets.isEmpty else { return }
            let rects = paneRects()
            var varied = rects
            for (m, t) in targets { varied[m] = t }
            guard let grown = GroupLayout.bounds(
                groups: groupMetas, panes: varied)[id] else { return }
            let foreign = GroupLayout.blockObstacles(
                moving: id, panes: varied, groups: groupMetas,
                floating: floatingPanes())
            if foreign.contains(where: { Overlap.overlaps(grown, $0) }) {
                // Static world by default: SLIDE the block along the
                // collision (nothing else moves). Opt-in
                // (allow-mouse-drag-to-push): foreigners yield instead.
                if !GCTConfig.current.allowMouseDragToPush {
                    let clean = Overlap.resolve(
                        NSRectOverlap.from(NSRect(
                            x: b0.minX + dx, y: b0.minY + dy,
                            width: b0.width, height: b0.height)),
                        obstacles: foreign)
                    // Snap AFTER the slide resolve (shove path below
                    // returns early, unsnapped): post-resolve member
                    // frames, so the snap and guides sit on pane
                    // edges, not the padded union.
                    var slid = [PaneID: NSRect]()
                    let sdx0 = clean.x - Double(b0.minX),
                        sdy0 = clean.y - Double(b0.minY)
                    for m in members {
                        guard let r0 = rects0[m] else { continue }
                        slid[m] = NSRect(x: r0.minX + sdx0, y: r0.minY + sdy0,
                                         width: r0.width, height: r0.height)
                    }
                    let s = snapBlockDelta(members: slid, ids: Set(members))
                    for m in members {
                        guard let pane = panes[m], let r0 = rects0[m] else { continue }
                        pane.setRect(NSRect(x: r0.minX + sdx0 + Double(s.x),
                                            y: r0.minY + sdy0 + Double(s.y),
                                            width: r0.width, height: r0.height),
                                     notifySurface: false)
                    }
                    refreshGroupViews()
                    refreshOcclusion()
                    return
                }
                let (axis, sign): (Overlap.Axis, Int)
                if abs(dx) >= abs(dy), dx != 0 {
                    axis = .horizontal; sign = dx > 0 ? 1 : -1
                } else if dy != 0 {
                    axis = .vertical; sign = dy > 0 ? 1 : -1
                } else {
                    return // no motion: hold
                }
                let moves = GroupLayout.shoveAside(
                    grown: grown, moving: members[0], memberOf: Set([id]),
                    panes: varied, groups: groupMetas,
                    axis: axis, sign: sign,
                    allowOverlap: GCTConfig.current.allowWindowOverlap,
                    floating: floatingPanes())
                var check = varied
                for (pid, r) in moves { check[pid] = r }
                guard shoveClearsBlock(grown: grown, id: id,
                                        panes: check) else { return }
                for (pid, r) in moves {
                    guard let pane = panes[pid] else { continue }
                    let frame = NSRectOverlap.to(r)
                    guard frame != pane.frame else { continue }
                    pane.setRect(frame, notifySurface: false)
                    conn?.movePane(MovePane(
                        id: pid, rect: r,
                        allowOverlap: GCTConfig.current.allowWindowOverlap))
                }
            }
            // Free path: no obstacle contact. Snap MEMBER frames (not
            // the padded union), ride rigid. refreshGroupViews rides
            // along so the group background tracks the members live.
            var free = [PaneID: NSRect]()
            for m in members {
                guard let r0 = rects0[m] else { continue }
                free[m] = NSRect(x: r0.minX + dx, y: r0.minY + dy,
                                 width: r0.width, height: r0.height)
            }
            let s = snapBlockDelta(members: free, ids: Set(members))
            for m in members {
                guard let pane = panes[m], let r0 = rects0[m] else { continue }
                pane.setRect(NSRect(x: r0.minX + dx + s.x, y: r0.minY + dy + s.y,
                                    width: r0.width, height: r0.height),
                             notifySurface: false)
            }
            refreshGroupViews()
            refreshOcclusion()
        case .multiMove(let members, let rects0, let anchor):
            let world = worldPoint(event)
            let dx = world.x - anchor.x, dy = world.y - anchor.y
            // Rigid block: shift grab-time frames by the cursor delta,
            // drop panes that no longer exist. The whole SELECTION
            // resolves as one union rect against foreign obstacles (same
            // static-world rule as group drags: slide, never shove), so
            // relative offsets survive and the block never shears.
            var targets = [PaneID: NSRect]()
            for m in members {
                guard let r0 = rects0[m], panes[m] != nil else { continue }
                targets[m] = NSRect(x: r0.minX + dx, y: r0.minY + dy,
                                    width: r0.width, height: r0.height)
            }
            guard !targets.isEmpty,
                  let union1 = groupBoundsFrom(targets) else { return }
            let rects = paneRects()
            let floating = floatingPanes()
            var foreign = [Rect]()
            for (id, r) in rects where targets[id] == nil && !floating.contains(id) {
                foreign.append(r)
            }
            for (_, b) in GroupLayout.bounds(groups: groupMetas, panes: rects) {
                foreign.append(b)
            }
            let clean = Overlap.resolve(NSRectOverlap.from(union1), obstacles: foreign)
            // Snap AFTER the resolve: post-resolve member frames (not
            // the union), members ride the final delta rigidly.
            // Same-group-only selection snaps in-group (siblings); a
            // mixed/groupless selection uses block scope (ungrouped
            // frames + foreign borders). snapBlockDelta repaints guides.
            var slidTargets = [PaneID: NSRect]()
            let cdx = clean.x - Double(union1.minX),
                cdy = clean.y - Double(union1.minY)
            for (m, want) in targets {
                slidTargets[m] = NSRect(x: want.minX + cdx, y: want.minY + cdy,
                                        width: want.width, height: want.height)
            }
            let selIDs = Set(targets.keys)
            let selGroups = Set(selIDs.compactMap { groupOf($0) })
            let s: CGPoint
            if selGroups.count == 1, let only = selGroups.first,
               selIDs.isSubset(of: Set(groupMetas[only]?.members ?? [])) {
                // In-group: snap frames to non-selected siblings.
                // Sibling frames come from the post-resolve layout
                // (slidTargets when selected, live frames otherwise) —
                // stale pre-drag frames would offset every guide.
                let siblings = (groupMetas[only]?.members ?? []).compactMap { m -> NSRect? in
                    guard !selIDs.contains(m) else { return nil }
                    return slidTargets[m] ?? panes[m]?.frame
                }
                var sdx2: CGFloat = 0, sdy2: CGFloat = 0
                let inRadius = camera.screenToWorldDistance(GCTConfig.current.snapRadius)
                for m in slidTargets.values {
                    let r = SnapEngine.snapMove(m, others: siblings,
                                                radius: inRadius, mode: snapMode)
                    let dx = r.rect.minX - m.minX, dy = r.rect.minY - m.minY
                    if dx != 0, (sdx2 == 0 || abs(dx) < abs(sdx2)) { sdx2 = dx }
                    if dy != 0, (sdy2 == 0 || abs(dy) < abs(sdy2)) { sdy2 = dy }
                }
                var snapped = union1
                snapped.origin.x += cdx + Double(sdx2)
                snapped.origin.y += cdy + Double(sdy2)
                var gx = [CGFloat](), gy = [CGFloat]()
                for m in slidTargets.values {
                    let sx = m.minX + sdx2, mx = m.midX + sdx2, xx = m.maxX + sdx2
                    let sy = m.minY + sdy2, my = m.midY + sdy2, yy = m.maxY + sdy2
                    for o in siblings {
                        for (a, t) in [(sx, o.minX), (sx, o.maxX), (xx, o.minX), (xx, o.maxX)]
                            where snapMode != .center && abs(a - t) <= 0.5 && !gx.contains(t) { gx.append(t) }
                        if snapMode != .edges, abs(mx - o.midX) <= 0.5, !gx.contains(o.midX) { gx.append(o.midX) }
                        for (a, t) in [(sy, o.minY), (sy, o.maxY), (yy, o.minY), (yy, o.maxY)]
                            where snapMode != .center && abs(a - t) <= 0.5 && !gy.contains(t) { gy.append(t) }
                        if snapMode != .edges, abs(my - o.midY) <= 0.5, !gy.contains(o.midY) { gy.append(o.midY) }
                    }
                }
                showSnapGuides(x: gx, y: gy, near: snapped)
                s = CGPoint(x: sdx2, y: sdy2)
            } else {
                s = snapBlockDelta(members: slidTargets, ids: selIDs)
            }
            let sdx = cdx + Double(s.x)
            let sdy = cdy + Double(s.y)
            for (m, want) in targets {
                guard let pane = panes[m] else { continue }
                pane.setRect(NSRect(x: want.minX + sdx, y: want.minY + sdy,
                                    width: want.width, height: want.height),
                             notifySurface: false)
            }
            refreshGroupViews()
            refreshOcclusion()
        case .move(let id, let grabDelta):
            guard let pane = panes[id] else { return }
            let world = worldPoint(event)
            var rect = NSRect(x: world.x - grabDelta.x, y: world.y - grabDelta.y,
                              width: pane.frame.width,
                              height: pane.frame.height)
            let memberOf: Set<GroupID> = groupOf(id).map { Set([$0]) } ?? []
            let obstacles = GroupLayout.moveObstacles(
                moving: id, memberOf: memberOf, panes: paneRects(),
                groups: groupMetas,
                allowOverlap: GCTConfig.current.allowWindowOverlap,
                floating: floatingPanes())
            // Fast path preserves old behavior exactly: no groups, overlap
            // allowed = untouched.
            if !obstacles.isEmpty || !GCTConfig.current.allowWindowOverlap {
                rect = NSRectOverlap.to(Overlap.resolve(
                    NSRectOverlap.from(rect), obstacles: obstacles))
            }
            // Members: static world by default — slide along collisions
            // (frames via the resolve above, grown bounds via the slide
            // below), hold only when truly wedged. Opt-in
            // (allow-mouse-drag-to-push): shove foreigners aside instead.
            if let memberOf = groupOf(id) {
                if GCTConfig.current.allowMouseDragToPush {
                    let ok = shoveForeignForMember(
                        id: id, memberOf: memberOf,
                        candidate: NSRectOverlap.from(rect), from: pane.frame)
                    guard ok else { return }
                } else {
                    var candidate = NSRectOverlap.from(rect)
                    let floating = floatingPanes()
                    if GroupLayout.grownClash(
                        moving: id, memberOf: memberOf, candidate: candidate,
                        panes: paneRects(), groups: groupMetas,
                        floating: floating) {
                        candidate = GroupLayout.slideGrownRect(
                            candidate: candidate,
                            moving: id, memberOf: memberOf,
                            panes: paneRects(), groups: groupMetas,
                            floating: floating)
                        guard !GroupLayout.grownClash(
                            moving: id, memberOf: memberOf,
                            candidate: candidate,
                            panes: paneRects(), groups: groupMetas,
                            floating: floating) else {
                            return
                        }
                    }
                    rect = NSRectOverlap.to(candidate)
                }
            }
            // Snap AFTER the collision resolve: a drag-time nudge within
            // the radius, never a pass through other windows. Skipped on
            // the shove path above (that branch returns early).
            rect = snapMovedRect(rect, moving: id)
            pane.setRect(rect, notifySurface: false)
            // Grouped member: the background rides live (bounds derive
            // from frames). Untracked drags leave the pink box behind
            // until mouse-up.
            if groupOf(id) != nil {
                refreshGroupViews()
                refreshOcclusion()
            }
        case .resize(let id, let zone, let rect0):
            guard let pane = panes[id] else { return }
            let world = worldPoint(event)
            var rect = rect0
            let minW: CGFloat = 160, minH: CGFloat = 120
            if zone.resizesW {
                rect.origin.x = min(world.x, rect0.maxX - minW)
                rect.size.width = rect0.maxX - rect.origin.x
            }
            if zone.resizesE { rect.size.width = max(minW, world.x - rect0.minX) }
            if zone.resizesS {
                rect.origin.y = min(world.y, rect0.maxY - minH)
                rect.size.height = rect0.maxY - rect.origin.y
            }
            if zone.resizesN { rect.size.height = max(minH, world.y - rect0.minY) }
            // Snap the zone's moving edges BEFORE the collision clamp so
            // growing into a snapped neighbor holds at the shared edge.
            // Guides re-checked after the clamp (keepSnapGuides): an
            // over-eager snap the blocker pushed back drops its line.
            let snapped = snapResizedRect(rect, rect0: rect0, zone: zone,
                                          moving: id)
            rect = snapped.rect
            // Group bounds always block, even when overlap is allowed;
            // members additionally avoid loose panes.
            let memberOf: Set<GroupID> = groupOf(id).map { Set([$0]) } ?? []
            let obstacles = GroupLayout.moveObstacles(
                moving: id, memberOf: memberOf, panes: paneRects(),
                groups: groupMetas,
                allowOverlap: GCTConfig.current.allowWindowOverlap,
                floating: floatingPanes())
            if !GCTConfig.current.allowWindowOverlap || !obstacles.isEmpty {
                let clean = Overlap.clampResize(
                    NSRectOverlap.from(rect),
                    original: NSRectOverlap.from(rect0),
                    edges: Overlap.Edges(
                        w: zone.resizesW, e: zone.resizesE,
                        s: zone.resizesS, n: zone.resizesN),
                    obstacles: obstacles)
                rect = NSRectOverlap.to(clean)
            }
            // Members: static world by default — slide the grown bounds
            // along collisions, hold when wedged. Opt-in: shove instead.
            if let memberOf = groupOf(id) {
                if GCTConfig.current.allowMouseDragToPush {
                    // Axis from growth: E/W edges push horizontally, N/S
                    // vertically; corners take the dominant growth.
                    let gw = abs(rect.width - rect0.width)
                    let gh = abs(rect.height - rect0.height)
                    let ax: (Overlap.Axis, Int)
                    if zone.resizesE || (zone.resizesW && !zone.resizesN && !zone.resizesS) {
                        ax = (.horizontal, 1)
                    } else if zone.resizesW {
                        ax = (.horizontal, -1)
                    } else if zone.resizesN {
                        ax = (.vertical, 1)
                    } else if zone.resizesS {
                        ax = (.vertical, -1)
                    } else if gw >= gh {
                        ax = (.horizontal, rect.width >= rect0.width ? 1 : -1)
                    } else {
                        ax = (.vertical, rect.height >= rect0.height ? 1 : -1)
                    }
                    let ok = shoveForeignForMember(
                        id: id, memberOf: memberOf,
                        candidate: NSRectOverlap.from(rect), from: pane.frame,
                        axis: ax)
                    guard ok else { return }
                } else {
                    var candidate = NSRectOverlap.from(rect)
                    let floating = floatingPanes()
                    if GroupLayout.grownClash(
                        moving: id, memberOf: memberOf, candidate: candidate,
                        panes: paneRects(), groups: groupMetas,
                        floating: floating) {
                        candidate = GroupLayout.slideGrownRect(
                            candidate: candidate,
                            moving: id, memberOf: memberOf,
                            panes: paneRects(), groups: groupMetas,
                            floating: floating)
                        guard !GroupLayout.grownClash(
                            moving: id, memberOf: memberOf,
                            candidate: candidate,
                            panes: paneRects(), groups: groupMetas,
                            floating: floating) else {
                            return
                        }
                    }
                    rect = NSRectOverlap.to(candidate)
                }
            }
            pane.setRect(rect, notifySurface: true)
            // Guides sit on the frame (siblings-only scope) — keep what
            // survives the collision clamp.
            keepSnapGuides(x: snapped.guidesX, y: snapped.guidesY, on: rect)
            if groupOf(id) != nil {
                refreshGroupViews()
                refreshOcclusion()
            }
        case .surfaceClick(let id, _):
            // Selection/drag inside the terminal: keep ghostty's mouse
            // position current while the button is held. Without this the
            // core only ever sees press + release, so selections never
            // extend and mouse-drag tracking never fires.
            guard let pane = panes[id] else { return }
            let local = pane.surfacePoint(at: worldPoint(event))
            pane.host?.mousePos(x: local.x, y: local.y,
                                mods: GhosttyMods(event.modifierFlags))
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Opt-click (armed, never dragged): clear the arm, no pane.
        if pendingCreate != nil, isIdleDrag {
            pendingCreate = nil
            return
        }
        if case .create(let anchor) = drag {
            pendingCreate = nil
            let world = worldPoint(event)
            let drawn = snappedCreateRect(anchor: anchor, free: world)
            drag = .none
            hideSelectionBand()
            hideSnapGuides()
            snapSizeLabel?.hide()
            // Tiny box = a click, not a draw: no pane.
            if drawn.rect.width >= 40, drawn.rect.height >= 40 {
                createPane(at: drawn.rect)
            }
            return
        }
        pendingCreate = nil
        snapSizeLabel?.hide()
        if case .surfaceClick(let id, let button) = drag, let pane = panes[id] {
            let local = pane.surfacePoint(at: worldPoint(event))
            let mods = GhosttyMods(event.modifierFlags)
            pane.host?.mousePos(x: local.x, y: local.y, mods: mods)
            pane.host?.mouseButton(GHOSTTY_MOUSE_RELEASE, button, mods)
        }
        if case .move(let id, _) = drag, let pane = panes[id] {
            conn?.movePane(MovePane(id: id, rect: pane.meta.rect,
                            allowOverlap: GCTConfig.current.allowWindowOverlap))
        }
        if case .multiMove(let members, _, _) = drag {
            for m in members {
                guard let pane = panes[m] else { continue }
                conn?.movePane(MovePane(id: m, rect: pane.meta.rect,
                                allowOverlap: GCTConfig.current.allowWindowOverlap))
            }
        }
        if case .groupMove(let id, _, _, let rects0) = drag,
           let b0 = groupBoundsFrom(rects0),
           let b1 = groupBounds(id) {
            conn?.moveGroup(MoveGroup(id: id,
                                      dx: Double(b1.minX - b0.minX),
                                      dy: Double(b1.minY - b0.minY),
                                      allowOverlap: GCTConfig.current.allowWindowOverlap))
            refreshGroupViews()
        }
        if case .select = drag {
            finishSelectionBand()
        }
        drag = .none
        hideSelectionBand()
        hideSnapGuides()
    }

    // MARK: Right button — selection + groups live here
    // Left-click drags on empty space pan; the right button is free (no
    // rightMouseDown override existed, and surface clicks only forward
    // left/right presses that START on a pane). So: right-drag on empty
    // space rubber-bands panes into a STAGED MULTI-SELECT (no grouping
    // until asked); right-click with a live selection pops the selection
    // menu (group / close / clear); right-click on a group background
    // pops its menu (rename, color, ungroup); right-click on empty space
    // pans nothing and shows the canvas menu (new pane here).
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let world = worldPoint(event)
        // On a pane: forward to the terminal as before (apps like vim /
        // tmux expect right-click). No drag state: mouseUp ignores it.
        if let pane = topPane(at: world) {
            focusPane(pane.id)
            let local = pane.surfacePoint(at: world)
            let mods = GhosttyMods(event.modifierFlags)
            pane.host?.mousePos(x: local.x, y: local.y, mods: mods)
            pane.host?.mouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT,
                                   mods)
            drag = .surfaceClick(id: pane.id, button: GHOSTTY_MOUSE_RIGHT)
            return
        }
        if topGroup(at: world) != nil {
            // Click (no drag): menu on rightMouseUp. Possible drag:
            // arm a pending group move; rightMouseDragged confirms it.
            pendingRightGroup = world
            return
        }
        drag = .select(anchor: world)
        selectionBand = (anchor: world, current: world)
        showSelectionBand()
    }

    override func rightMouseDragged(with event: NSEvent) {
        // Rubber-band follows the right drag (started on empty space).
        if case .select(let anchor) = drag {
            selectionBand = (anchor: anchor, current: worldPoint(event))
            showSelectionBand()
            return
        }
        // Right-press started on a terminal: same selection/drag forwarding
        // as left (AppKit sends these to rightMouseDragged, not
        // mouseDragged).
        if case .surfaceClick(let id, _) = drag, let pane = panes[id] {
            let local = pane.surfacePoint(at: worldPoint(event))
            pane.host?.mousePos(x: local.x, y: local.y,
                                mods: GhosttyMods(event.modifierFlags))
            return
        }
        // Group background + right drag = same whole-group move as left.
        if pendingRightGroup != nil {
            let world = worldPoint(event)
            guard let g = topGroup(at: pendingRightGroup ?? world),
                  let b = groupBounds(g.id) else {
                pendingRightGroup = nil
                return
            }
            var rects = [PaneID: NSRect]()
            for m in groupMetas[g.id]?.members ?? [] {
                if let p = panes[m] { rects[m] = p.frame }
            }
            drag = .groupMove(id: g.id,
                              grabDelta: CGPoint(x: world.x - b.minX,
                                                 y: world.y - b.minY),
                              members: Array(rects.keys), rects0: rects)
            pendingRightGroup = nil
            return
        }
        super.rightMouseDragged(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        let world = worldPoint(event)
        // Release of a terminal right-click: forward the release.
        if case .surfaceClick(let id, let button) = drag,
           let pane = panes[id] {
            let local = pane.surfacePoint(at: world)
            let mods = GhosttyMods(event.modifierFlags)
            pane.host?.mousePos(x: local.x, y: local.y, mods: mods)
            pane.host?.mouseButton(GHOSTTY_MOUSE_RELEASE, button, mods)
            drag = .none
            return
        }
        // End of a rubber-band or group move: shared finish path. A tiny
        // band is a plain right-click (empty canvas starts the band on
        // press, so release always lands here): clear it and fall through
        // to the menu. Real drags stage the selection instead.
        if case .select = drag {
            if let band = selectionBand {
                let r = selectionRect(band)
                if r.width <= 8 || r.height <= 8 {
                    drag = .none
                    hideSelectionBand()
                } else {
                    mouseUp(with: event)
                    return
                }
            } else {
                drag = .none
            }
        }
        if case .groupMove = drag {
            mouseUp(with: event)
            return
        }
        // Plain right-click: one unified menu on any non-pane click
        // (empty space or group background) — selection actions when a
        // selection is live, group actions on its background, always
        // with "New pane here". Right-clicks ON a pane still go to the
        // terminal (vim / tmux expect them).
        pendingRightGroup = nil
        if topPane(at: world) == nil {
            showCanvasMenu(at: event, world: world)
        }
    }
    // Group menu construction now lives in showCanvasMenu (unified menu).
    // Kept as a redirect so any external callers still land correctly.
    func showGroupMenu(_ id: GroupID, at event: NSEvent) {
        guard let b = groupBounds(id) else { return }
        showCanvasMenu(at: event, world: CGPoint(x: b.midX, y: b.midY))
    }
    // Right-click on non-pane canvas: ONE menu, always. Group background
    // adds rename/color/ungroup; a live selection adds group/close/
    // clear; "New pane here" is always present.
    func showCanvasMenu(at event: NSEvent, world: CGPoint) {
        let menu = NSMenu()
        let groupBG = topGroup(at: world)
        let sel = liveSelected()

        if !sel.isEmpty {
            let title = NSMenuItem(title: "\(sel.count) panes selected",
                                   action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)

            let group = NSMenuItem(title: "Group selection…",
                                   action: #selector(groupSelectionFromMenu(_:)),
                                   keyEquivalent: "")
            group.target = self
            menu.addItem(group)

            let close = NSMenuItem(title: "Close \(sel.count) panes",
                                   action: #selector(closeSelectionFromMenu(_:)),
                                   keyEquivalent: "")
            close.target = self
            menu.addItem(close)

            let clear = NSMenuItem(title: "Clear selection",
                                   action: #selector(clearSelectionFromMenu(_:)),
                                   keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
            menu.addItem(.separator())
        }

        if let g = groupBG, let meta = groupMetas[g.id] {
            let id = g.id
            let title = NSMenuItem(title: meta.name ?? "Group", action: nil,
                                   keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)

            let rename = NSMenuItem(title: "Rename group…",
                                    action: #selector(renameGroupFromMenu(_:)),
                                    keyEquivalent: "")
            rename.target = self
            rename.representedObject = id.uuid.uuidString
            menu.addItem(rename)

            let colors = NSMenuItem(title: "Group color", action: nil, keyEquivalent: "")
            let palette = NSMenu(title: "Group color")
            for hex in GroupStyle.palette {
                let item = NSMenuItem(title: hex,
                                      action: #selector(recolorGroupFromMenu(_:)),
                                      keyEquivalent: "")
                item.target = self
                // "id|hex" — representedObject is Any?.
                item.representedObject = id.uuid.uuidString + "|" + hex
                item.attributedTitle = NSAttributedString(
                    string: "  \(hex)",
                    attributes: [.foregroundColor: NSColor(gctHex: hex) ?? .labelColor])
                palette.addItem(item)
            }
            colors.submenu = palette
            menu.addItem(colors)

            let ungroup = NSMenuItem(title: "Ungroup",
                                     action: #selector(ungroupFromMenu(_:)),
                                     keyEquivalent: "")
            ungroup.target = self
            ungroup.representedObject = id.uuid.uuidString
            menu.addItem(ungroup)
            menu.addItem(.separator())
        }

        let here = NSMenuItem(title: "New pane here",
                              action: #selector(newPaneHereFromMenu(_:)),
                              keyEquivalent: "")
        here.target = self
        here.representedObject = NSStringFromPoint(world)
        menu.addItem(here)
        menu.addItem(.separator())
        let snap = NSMenuItem(
            title: GCTConfig.current.snapping
                ? "Snapping: on" : "Snapping: off",
            action: #selector(toggleSnappingFromMenu(_:)),
            keyEquivalent: "")
        snap.target = self
        snap.state = GCTConfig.current.snapping ? .on : .off
        menu.addItem(snap)
    }
    @objc func groupSelectionFromMenu(_ sender: NSMenuItem) {
        groupStagedSelection()
    }

    @objc func closeSelectionFromMenu(_ sender: NSMenuItem) {
        let ids = liveSelected()
        guard !ids.isEmpty else { return }
        clearSelection()
        for id in ids { closePane(id) }
    }

    @objc func clearSelectionFromMenu(_ sender: NSMenuItem) {
        clearSelection()
    }

    @objc func toggleSnappingFromMenu(_ sender: NSMenuItem) {
        toggleSnapping()
    }

    @objc func renameGroupFromMenu(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String,
              let u = UUID(uuidString: s) else { return }
        promptRenameGroup(GroupID(u))
    }

    @objc func recolorGroupFromMenu(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        let parts = s.split(separator: "|").map(String.init)
        guard parts.count == 2, let u = UUID(uuidString: parts[0]),
              let hex = GroupStyle.sanitizedColor(parts[1]) else { return }
        let id = GroupID(u)
        guard var g = groupMetas[id] else { return }
        g.color = hex
        groupMetas[id] = g
        refreshGroupViews()
        conn?.updateGroup(UpdateGroup(id: id, name: g.name,
                                      color: g.color, members: g.members))
    }

    @objc func ungroupFromMenu(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String,
              let u = UUID(uuidString: s) else { return }
        ungroup(GroupID(u))
    }

    @objc func newPaneHereFromMenu(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        let p = NSPointFromString(s)
        let cwd = focusedID.flatMap { panes[$0]?.meta.cwd }
        var r = newPaneRect()
        r.origin = CGPoint(x: p.x - r.width / 2, y: p.y - r.height / 2)
        let obstacles = GroupLayout.creationObstacles(
            paneRects: paneRects(),
            groups: groupMetas,
            allowOverlap: GCTConfig.current.allowWindowOverlap,
            floating: floatingPanes())
        if !GCTConfig.current.allowWindowOverlap || !obstacles.isEmpty {
            r = NSRectOverlap.to(Overlap.resolve(NSRectOverlap.from(r),
                                                 obstacles: obstacles))
        }
        conn?.createPane(CreatePane(
            rect: Rect(x: r.minX, y: r.minY, w: r.width, h: r.height),
            cwd: cwd,
            allowOverlap: GCTConfig.current.allowWindowOverlap))
    }

    override func mouseMoved(with event: NSEvent) {
        // Hover routing: the pane under the cursor gets position updates
        // (link highlighting, hover shapes), not just the focused pane.
        // Ghostty treats (-1,-1) as "left the viewport", so tell the old
        // focus it left when the cursor moves onto another pane/empty.
        let world = worldPoint(event)
        let mods = GhosttyMods(event.modifierFlags)
        let hovered = topPane(at: world)
        if GCTConfig.current.focusFollowsMouse, let h = hovered,
           h.id != focusedID, !isResizingOrMoving {
            focusPane(h.id, raise: false)
        }
        if let h = hovered {
            let local = h.surfacePoint(at: world)
            h.host?.mousePos(x: local.x, y: local.y, mods: mods)
        }
        if let id = focusedID, id != hovered?.id,
           let pane = panes[id] {
            pane.host?.mousePos(x: -1, y: -1, mods: mods)
        }
    }

    // A resize/move drag owns the cursor: focus-follows-mouse must not
    // steal focus mid-gesture.
    private var isResizingOrMoving: Bool {
        switch drag {
        case .resize, .move, .multiMove, .groupMove, .create: return true
        default: return false
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Hover routes the scroll: over a terminal surface it goes to the
        // terminal (scrollback, alt-screen, mouse reporting — the core
        // decides), anywhere else it zooms the canvas at the cursor. No
        // modifier needed, wheel and trackpad alike. Deltas already honor
        // the user's scroll-direction preference; momentum-phase events
        // take the same path, giving inertial scroll/zoom for free.
        // Shape mirrors Ghostty's own SurfaceView: raw deltas (2x for
        // precise devices), precision+momentum packed into scroll mods.
        if GCTConfig.current.scrollOnTerminalHover {
            let world = worldPoint(event)
            if let pane = topPane(at: world), pane.surfaceContains(world) {
                let m = event.hasPreciseScrollingDeltas ? 2.0 : 1.0
                pane.host?.mouseScroll(x: event.scrollingDeltaX * m,
                                       y: event.scrollingDeltaY * m,
                                       mods: GhosttyScrollMods(event))
                return
            }
            cancelCameraAnim()
            let p = viewPoint(event)
            camera.zoom(at: p, factor: exp(-event.scrollingDeltaY / 400))
            rebasePanDrag(around: p)
            applyCamera()
            return
        }
        // Legacy path (scroll-on-terminal-hover = false): precise
        // two-finger scroll pans, shift+wheel (which macOS delivers as a
        // horizontal scroll) goes to the terminal, plain wheel zooms.
        if event.hasPreciseScrollingDeltas
            && event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty {
            cancelCameraAnim()
            camera.offset.x -= event.scrollingDeltaX
            camera.offset.y -= event.scrollingDeltaY
            rebasePanDrag(around: viewPoint(event))
            applyCamera()
            return
        }
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            || event.modifierFlags.contains(.shift) {
            let pane = topPane(at: worldPoint(event)) ?? focusedID.flatMap { panes[$0] }
            pane?.host?.mouseScroll(x: event.scrollingDeltaX,
                                    y: event.scrollingDeltaY,
                                    mods: GhosttyScrollMods(event))
            return
        }
        cancelCameraAnim()
        let p = viewPoint(event)
        camera.zoom(at: p, factor: exp(-event.scrollingDeltaY / 400))
        rebasePanDrag(around: p)
        applyCamera()
    }

    // Pinch: zoom anchored at the cursor. Per-event magnification is a
    // delta since the last event, so 1+m composes into the full gesture.
    override func magnify(with event: NSEvent) {
        cancelCameraAnim()
        let p = viewPoint(event)
        camera.zoom(at: p, factor: 1 + event.magnification)
        rebasePanDrag(around: p)
        applyCamera()
    }

    // Two-finger double-tap: toggle actual size at the tap vs fit-all.
    override func smartMagnify(with event: NSEvent) {
        if camera.scale >= Camera.maxScale - 0.001 {
            fitAll()
            return
        }
        var target = camera
        target.zoom(at: viewPoint(event),
                    factor: Camera.maxScale / camera.scale)
        animateCamera(to: target)
    }

    // Manual camera input cancels an in-flight focus/fit animation so the
    // gesture owns the camera immediately instead of fighting the timer.
    private func cancelCameraAnim() {
        cameraAnim?.0.invalidate()
        cameraAnim = nil
    }

    // Gestures move the camera outside the left-drag pan math; rebase an
    // in-progress pan so the next mouseDragged continues from the new
    // camera instead of snapping back to the drag start.
    private func rebasePanDrag(around p: CGPoint) {
        if case .pan(let start, _) = drag {
            drag = .pan(start: start, offset0: CGPoint(
                x: camera.offset.x - (p.x - start.x),
                y: camera.offset.y - (p.y - start.y)))
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Doom fallback: the toggle combo works locally while frontmost.
        // When Carbon registration succeeded, the system eats the combo
        // before it reaches us, so this only fires when the global
        // hotkey failed (or doom is off and a stale config still names
        // the toggle). Posts a notification; the DoomController toggles.
        if GCTConfig.current.doom.enabled,
           let t = GCTConfig.current.doom.toggle,
           t.matches(event) || t.matchesKeyCode(event) {
            NotificationCenter.default.post(name: .gctToggleDoom, object: nil)
            return
        }
        // App shortcuts first, from the config's keybinds.
        if let action = GCTAction.allCases.first(where: {
            GCTConfig.current.keybinds[$0]?.matches(event) ?? false
        }) {
            perform(action)
            return
        }

        guard let host = focusedHost else {
            super.keyDown(with: event)
            return
        }

        handleKey(event, to: host)
    }

    private func perform(_ action: GCTAction) {
        switch action {
        case .newPane: newPane()
        case .closePane: closeSelectedOrFocused()
        case .renamePane: renameFocusedOrGroup()
        case .moveFocusAbove: moveFocus(.above)
        case .moveFocusBelow: moveFocus(.below)
        case .moveFocusLeft: moveFocus(.left)
        case .moveFocusRight: moveFocus(.right)
        case .openNewAbove: newPane(direction: .above)
        case .openNewBelow: newPane(direction: .below)
        case .openNewLeft: newPane(direction: .left)
        case .openNewRight: newPane(direction: .right)
        case .growAbove: resizeFocused(edge: .above, grow: true)
        case .growBelow: resizeFocused(edge: .below, grow: true)
        case .growLeft: resizeFocused(edge: .left, grow: true)
        case .growRight: resizeFocused(edge: .right, grow: true)
        case .shrinkAbove: resizeFocused(edge: .above, grow: false)
        case .shrinkBelow: resizeFocused(edge: .below, grow: false)
        case .shrinkLeft: resizeFocused(edge: .left, grow: false)
        case .shrinkRight: resizeFocused(edge: .right, grow: false)
        case .switcher: toggleSwitcher()
        case .fitAll: fitAll()
        case .copy: copyFromFocused()
        case .paste: pasteIntoFocused()
        case .groupSelection: groupStagedSelection()
        case .ungroup:
            if let id = focusedID, let gid = groupOf(id) { ungroup(gid) }
        case .toggleFloating: toggleFloating()
        case .togglePaneSelection:
            if let id = focusedID { toggleSelected(id) }
        case .clearPaneSelection: clearSelection()
        case .toggleSnapping: toggleSnapping()
        }
    }

    // Rename targets the focused pane's GROUP when it has one (the name
    // shows on the background), else the pane itself.
    func renameFocusedOrGroup() {
        if let id = focusedID, let gid = groupOf(id) {
            promptRenameGroup(gid)
        } else if let id = focusedID {
            renamePane(id)
        }
    }

    // cmd+g with no staged selection renames the focused pane's group
    // (no group = no-op). With a 2+ staged selection, groupStagedSelection
    // (the perform path) creates the group instead.
    func promptGroupSelection() {
        if let id = focusedID, let gid = groupOf(id) {
            promptRenameGroup(gid)
        }
    }

    func promptRenameGroup(_ id: GroupID) {
        promptName(title: "Rename group",
                   initial: groupMetas[id]?.name ?? "") { [weak self] name in
            self?.renameGroup(id, name: name)
        }
    }

    func promptName(title: String, initial: String,
                    done: @escaping (String?) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { _ in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            done(name.isEmpty ? nil : name)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let id = focusedID, let pane = panes[id], let host = pane.host else {
            super.flagsChanged(with: event)
            return
        }
        let mods = GhosttyMods(event.modifierFlags)
        let mod: UInt32
        switch event.keyCode {
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        let action: ghostty_input_action_e =
            mods.rawValue & mod != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        _ = keyAction(action, event: event, translationEvent: nil, to: host)
    }

    // Route a key event through the text input system first (so dead keys
    // and IMEs see it), then encode both the raw key and any committed text
    // to ghostty. Mirrors Ghostty's macOS SurfaceView.keyDown.
    private func handleKey(_ event: NSEvent, to host: SurfaceHost) {
        guard let surface = host.surfaceIfOpen() else { return }

        // Translate the mods to honor configs such as option-as-alt.
        let translated = ghostty_surface_key_translation_mods(
            surface, GhosttyMods(event.modifierFlags)).rawValue
        var translationMods = event.modifierFlags
        for (flag, mask) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT.rawValue),
                             (.control, GHOSTTY_MODS_CTRL.rawValue),
                             (.option, GHOSTTY_MODS_ALT.rawValue),
                             (.command, GHOSTTY_MODS_SUPER.rawValue)] {
            if translated & mask != 0 {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // IMPORTANT: reuse the original event when the mods match. AppKit
        // keys off event object equality for Korean input to work.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action: ghostty_input_action_e =
            event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // interpretKeyEvents feeds the event to the active input method,
        // which calls back into insertText/setMarkedText.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0

        // If the layout changes while handling this event, an input method
        // grabbed it and we do nothing.
        let keyboardIdBefore = markedTextBefore ? nil : KeyboardLayout.id

        interpretKeyEvents([translationEvent])

        if !markedTextBefore, keyboardIdBefore != KeyboardLayout.id { return }

        // Push the preedit the IME left behind to the surface, which
        // renders the in-progress composition inline at the cursor.
        syncPreedit(clearIfNeeded: markedTextBefore)

        // Composing if preedit exists now or existed before: the key press
        // itself belongs to the IME. Example: Japanese composing, then
        // backspace or ctrl+h should only cancel the composition, not
        // delete previously committed input.
        let composing = markedText.length > 0 || markedTextBefore

        if markedTextBefore, let list = keyTextAccumulator, !list.isEmpty {
            // The IME committed (part of) the preedit while handling this
            // key. Send the committed text on its own, then replay only
            // keys that still affect the terminal after committing.
            for text in list {
                if Self.shouldSuppressComposingControlInput(text, composing: composing) {
                    continue
                }
                _ = committedTextAction(action, text: text, to: host)
            }
            if Self.shouldReplayCommittedPreeditKey(translationEvent) {
                _ = keyAction(action, event: event,
                              translationEvent: translationEvent,
                              composing: false, to: host)
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            // The IME committed text for this key; encode each chunk with
            // the key event so programs treat it as typed input.
            for text in list {
                if Self.shouldSuppressComposingControlInput(text, composing: composing) {
                    continue
                }
                _ = keyAction(action, event: event,
                              translationEvent: translationEvent,
                              text: text, to: host)
            }
        } else {
            // Raw control characters arriving during composition belong to
            // the IME, not the terminal.
            if Self.shouldSuppressComposingControlInput(event.characters,
                                                        composing: composing) {
                return
            }

            // Normal key event: ghostty encodes from the keycode.
            _ = keyAction(action, event: event,
                          translationEvent: translationEvent,
                          text: Self.ghosttyCharacters(translationEvent),
                          composing: composing, to: host)
        }
    }

    // Encode a key event (with optional text) to the surface.
    private func keyAction(_ action: ghostty_input_action_e,
                           event: NSEvent,
                           translationEvent: NSEvent?,
                           text: String? = nil,
                           composing: Bool = false,
                           to host: SurfaceHost) -> Bool {
        var ev = Self.ghosttyKeyEvent(event, action,
                                      translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        if let text = text?.keyEventText {
            return text.withCString { ptr in
                ev.text = UnsafePointer(ptr)
                return host.key(ev)
            }
        }
        return host.key(ev)
    }

    // Committed IME text outside a key event (dictation, etc.): a
    // text-only key event with no key or mods.
    private func committedTextAction(_ action: ghostty_input_action_e,
                                     text: String, to host: SurfaceHost) -> Bool {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = 0
        ev.text = nil
        ev.composing = false
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        ev.unshifted_codepoint = 0
        return text.withCString { ptr in
            ev.text = UnsafePointer(ptr)
            return host.key(ev)
        }
    }

    // NSEvent -> ghostty key event, mirrors Ghostty's own macOS conversion.
    private static func ghosttyKeyEvent(_ event: NSEvent, _ action: ghostty_input_action_e,
                                        translationMods: NSEvent.ModifierFlags?)
        -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(event.keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = GhosttyMods(event.modifierFlags)
        // control/command never contribute to text translation.
        ev.consumed_mods = GhosttyMods(
            (translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            ev.unshifted_codepoint = cp.value
        }
        return ev
    }

    // event.characters filtered for ghostty key events: control characters
    // are re-derived without control (ghostty encodes control keys itself,
    // from the key enum), and PUA function-key values are dropped.
    private static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers:
                    event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return chars
    }

    // True when `text` is a single C0 control character arriving while the
    // IME is composing; such input belongs to the IME, not the terminal.
    private static func shouldSuppressComposingControlInput(_ text: String?,
                                                            composing: Bool) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return false
        }
        return scalar.value < 0x20
    }

    // After an IME commits preedit while handling a key, replay only keys
    // that still affect the terminal (arrows). Plain left-arrow is excluded:
    // AppKit already leaves the caret in place after Korean IMEs commit.
    private static func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 124, 125, 126: return true // right, down, up
        case 123: // left
            return !event.modifierFlags.isDisjoint(
                with: [.shift, .control, .option, .command])
        default: return false
        }
    }

    private func pasteIntoFocused() {
        guard let id = focusedID, let pane = panes[id] else { return }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        pane.host?.text(text)
    }

    private func copyFromFocused() {
        guard let id = focusedID, let pane = panes[id] else { return }
        if let selection = pane.host?.copySelection() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selection, forType: .string)
            return
        }
        // No selection: cmd+c acts like ^C.
        var ev = ghostty_input_key_s()
        ev.action = GHOSTTY_ACTION_PRESS
        ev.mods = GHOSTTY_MODS_CTRL
        let c = strdup("\u{03}")
        if let c { ev.text = UnsafePointer(c) }
        defer { free(c) }
        _ = pane.host?.key(ev)
    }

    // Push the current preedit (or clear it) to the focused surface so the
    // in-progress composition renders inline at the cursor.
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let host = markedHost ?? focusedHost,
              let surface = host.surfaceIfOpen() else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    // Subtract 1 for the null terminator.
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // Swallow unhandled input-context commands so interpretKeyEvents
    // doesn't fall through to a system NSBeep.
    override func doCommand(by selector: Selector) {}

    // MARK: Pane lifecycle

    func newPane() {
        newPane(direction: GCTConfig.current.newWindowDirection)
    }

    // Directional open-new-window-*: same size rule and overlap handling
    // as cmd+t, on the action's fixed side. Focus/camera follow only via
    // move-focus-on-new-window (center) and camera-follows/fits-focus-move
    // (center/fit on arrival) — see connPaneCreated. From a grouped pane
    // the split joins that group via CreatePane.joinGroup (daemon-side).
    func newPane(direction: GCTNewWindowDirection) {
        // Inherit the focused pane's group: the daemon places the split
        // inside the own group's bounds, shoves loose blockers aside
        // along the split axis when the grown bounds demand it, and
        // admits it (refusal = groupless pane).
        let cwd = focusedID.flatMap { panes[$0]?.meta.cwd }
        let inheritGroup = focusedID.flatMap { groupOf($0) }
        let r = newPaneRect(direction: direction, ignoringGroup: inheritGroup)
        conn?.createPane(CreatePane(
            rect: Rect(x: r.minX, y: r.minY, w: r.width, h: r.height),
            cwd: cwd,
            allowOverlap: GCTConfig.current.allowWindowOverlap,
            joinGroup: inheritGroup, joinDirection: direction.rawValue))
    }

    // Drag-to-create: open a pane at the drawn rect (already snapped).
    // Same overlap/group rules as "New pane here", same cwd inheritance.
    func createPane(at rect: NSRect) {
        let cwd = focusedID.flatMap { panes[$0]?.meta.cwd }
        var r = rect
        let obstacles = GroupLayout.creationObstacles(
            paneRects: paneRects(),
            groups: groupMetas,
            allowOverlap: GCTConfig.current.allowWindowOverlap,
            floating: floatingPanes())
        if !GCTConfig.current.allowWindowOverlap || !obstacles.isEmpty {
            r = NSRectOverlap.to(Overlap.resolve(NSRectOverlap.from(r),
                                                 obstacles: obstacles))
        }
        conn?.createPane(CreatePane(
            rect: Rect(x: r.minX, y: r.minY, w: r.width, h: r.height),
            cwd: cwd,
            allowOverlap: GCTConfig.current.allowWindowOverlap))
    }

    // New-pane placement: flush against the focused pane on the given
    // side (cmd+t passes the configured direction; open-new-window-*
    // passes its fixed side), sized per config (focused pane's size, a
    // fixed grid, or a standard 80x24 terminal when nothing is focused).
    // With overlap disallowed the rect is pushed clear of every other pane.
    func newPaneRect(direction: GCTNewWindowDirection? = nil,
                     ignoringGroup: GroupID? = nil) -> NSRect {
        let cfg = GCTConfig.current
        let dir = direction ?? cfg.newWindowDirection
        let focused = focusedID.flatMap { panes[$0] }

        // Provisional until replaced below; also the virgin-canvas
        // fallback (no surface yet to measure cells from — the grid fixup
        // corrects it once one exists).
        var size = NSSize(width: 900, height: 560)
        var grid: (cols: Int, rows: Int)?
        switch cfg.newWindowDim {
        case .fixed(let cols, let rows):
            grid = (cols, rows)
        case .follows:
            if let f = focused?.frame {
                size = f.size
            } else {
                grid = (80, 24)  // standard terminal size
            }
        }
        if let grid, let measured = frameForGrid(grid.cols, grid.rows) {
            size = measured
        } else if let grid {
            pendingGridFixup = grid
        }

        let origin: CGPoint
        if let f = focused?.frame {
            switch dir {
            case .right: origin = CGPoint(x: f.maxX, y: f.minY)
            case .left:  origin = CGPoint(x: f.minX - size.width, y: f.minY)
            case .above: origin = CGPoint(x: f.minX, y: f.maxY)
            case .below: origin = CGPoint(x: f.minX, y: f.minY - size.height)
            }
        } else {
            origin = .zero
        }

        var rect = NSRect(origin: origin, size: size)
        // Group bounds always block new panes, even when overlap is
        // allowed; pane frames follow the overlap policy. Floating
        // panes never block. A group-inheriting split ignores its OWN
        // group's bounds (flush sibling lands inside them) — foreign
        // groups still block, and the daemon admits on arrival.
        var obstacles = GroupLayout.creationObstacles(
            paneRects: paneRects(),
            groups: groupMetas,
            allowOverlap: cfg.allowWindowOverlap,
            floating: floatingPanes())
        if let own = ignoringGroup,
           let b = GroupLayout.bounds(groups: groupMetas, panes: paneRects())[own] {
            obstacles.removeAll { $0 == b }
        }
        if !cfg.allowWindowOverlap || !obstacles.isEmpty {
            if cfg.allowWindowOverlap {
                let clean = Overlap.resolve(NSRectOverlap.from(rect),
                                            obstacles: obstacles)
                rect = NSRectOverlap.to(clean)
            } else {
                let (axis, sign): (Overlap.Axis, Int) = switch dir {
                case .right: (.horizontal, 1)
                case .left: (.horizontal, -1)
                case .above: (.vertical, 1)
                case .below: (.vertical, -1)
                }
                // Directional placement, then full resolve so group
                // bounds (not just pane frames) also hold.
                var placed = Overlap.resolve(NSRectOverlap.from(rect), direction: sign,
                    axis: axis, obstacles: paneRects().filter { !floatingPanes().contains($0.key) }.map(\.value))
                placed = Overlap.resolve(placed, obstacles: obstacles)
                rect = NSRectOverlap.to(placed)
            }
        }
        return rect
    }

    // Frame size for a cols x rows grid, from measured cell metrics.
    // Includes titlebar + side/bottom border so grid panes open at the
    // requested terminal size.
    private func frameForGrid(_ cols: Int, _ rows: Int) -> NSSize? {
        guard let cell = cellSize else { return nil }
        let bw = GCTTheme.current.borderWidth
        return NSSize(width: CGFloat(cols) * cell.width + bw * 2,
                      height: CGFloat(rows) * cell.height + PaneView.titleBarHeight + bw)
    }

    func closePane(_ id: PaneID) {
        conn?.closePane(id)
    }

    func renamePane(_ id: PaneID) {
        guard let pane = panes[id], let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename pane"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = pane.meta.name ?? ""
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] _ in
            guard let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.conn?.renamePane(RenamePane(id: id, name: name.isEmpty ? nil : name))
        }
    }

    func removePane(_ id: PaneID) {
        guard let pane = panes[id] else { return }
        if markedHost === pane.host { dropComposition() }
        pane.host?.close()
        pane.removeFromSuperview()
        panes.removeValue(forKey: id)
        zOrder.removeAll { $0 == id }
        selectedIDs.remove(id)
        if focusedID == id {
            focusedID = nil
            if let last = zOrder.last { focusPane(last) }
        }
        refreshGroupViews()
    }

    func makePaneView(_ meta: PaneMeta) {
        guard panes[meta.id] == nil else { return }
        let pane = PaneView(meta: meta)
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        // cmd-+/- zoom lives per-surface: new panes inherit the focused
        // pane's size (0 = config default when window-inherit-font-size
        // is off or nothing is focused).
        let fontSize: Float = focusedID.flatMap { panes[$0]?.host?.surfaceIfOpen() }
            .map { ghostty_surface_inherited_config($0, GHOSTTY_SURFACE_CONTEXT_WINDOW).font_size } ?? 0
        let host = SurfaceHost(paneID: meta.id, hostView: pane.surfaceHostView,
                               scale: scale, app: ghosttyApp!.app,
                               delegate: self, fontSize: fontSize)
        host.connSend = { [weak self] id, data in
            self?.conn?.sendInput(id, data)
        }
        pane.install(host: host)
        refreshCellMetrics(host)
        applyPendingGridFixup(pane)
        panes[meta.id] = pane
        zOrder.append(meta.id)
        worldView.addSubview(pane)
        refreshGroupViews()

        // Attach after the surface exists; the daemon answers with the
        // scrollback ring, then live output.
        conn?.attachPane(AttachPane(id: meta.id, cols: 80, rows: 24))
        focusPane(meta.id)

        // One layout pass later, push the real pixel size.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.panes[meta.id]?.syncSurfaceSize()
            self?.refreshOcclusion()
        }
    }

    // All panes share the ghostty app config, so any open surface yields
    // the same cell metrics; keep the latest measurement.
    private func refreshCellMetrics(_ host: SurfaceHost) {
        guard let m = host.surfaceMetrics() else { return }
        cellSize = CGSize(width: m.cellWidth, height: m.cellHeight)
    }

    // A grid-sized pane created on an empty canvas got a provisional
    // frame (no surface existed to measure cell size). Its surface now
    // exists: correct the frame and persist the fixed rect.
    private func applyPendingGridFixup(_ pane: PaneView) {
        guard let grid = pendingGridFixup, let cell = cellSize else { return }
        pendingGridFixup = nil
        let bw = GCTTheme.current.borderWidth
        let target = NSSize(width: CGFloat(grid.cols) * cell.width + bw * 2,
                            height: CGFloat(grid.rows) * cell.height
                                + PaneView.titleBarHeight + bw)
        guard abs(pane.frame.width - target.width) > 0.5
                || abs(pane.frame.height - target.height) > 0.5 else { return }
        let rect = NSRect(origin: pane.frame.origin, size: target)
        pane.setRect(rect, notifySurface: false)
        conn?.movePane(MovePane(id: pane.id,
                                rect: Rect(x: rect.minX, y: rect.minY,
                                           w: rect.width, h: rect.height),
                                allowOverlap: GCTConfig.current.allowWindowOverlap))
        refreshOcclusion()
    }

    // Loaded layouts can overlap (saved while overlap was allowed): push
    // each pane out of the ones before it, oldest first, and persist the
    // corrections. Group bounds always block non-members (even when
    // overlap stays allowed); members untangle within their own group.
    func untangleLoadedPanes() {
        // settled tracks placed frames WITH their pane ids, so grouped
        // members resolve against their group's (fresh) bounds instead of
        // double-counting member frames (see moveObstacles).
        var settled = [(PaneID, NSRect)]()
        let floating = floatingPanes()
        for id in zOrder {
            guard let pane = panes[id] else { continue }
            var rect = pane.frame
            // Floating panes stay where the daemon persisted them.
            if floating.contains(id) { settled.append((id, rect)); continue }
            // Fresh bounds every pane: earlier placements shift them.
            let live = GroupLayout.bounds(groups: groupMetas, panes: paneRects())
            let memberOf: Set<GroupID> = groupOf(id).map { Set([$0]) } ?? []
            var foreignMembers = Set<PaneID>()
            var obstacles = [Rect]()
            for (gid, b) in live where !memberOf.contains(gid) {
                obstacles.append(b)
                foreignMembers.formUnion(groupMetas[gid]?.members ?? [])
            }
            for (sid, srect) in settled
                where sid != id && !foreignMembers.contains(sid)
                    && !floating.contains(sid) {
                obstacles.append(NSRectOverlap.from(srect))
            }
            if !obstacles.isEmpty {
                let before = rect
                let clean = Overlap.resolve(NSRectOverlap.from(rect),
                                            obstacles: obstacles)
                rect = NSRectOverlap.to(clean)
                if rect != before {
                    pane.setRect(rect, notifySurface: false)
                    conn?.movePane(MovePane(
                        id: id,
                        rect: Rect(x: rect.minX, y: rect.minY,
                                   w: rect.width, h: rect.height),
                        allowOverlap: GCTConfig.current.allowWindowOverlap))
                }
            }
            settled.append((id, rect))
        }
        refreshGroupViews()
        refreshOcclusion()
    }
    // MARK: Keyboard resize

    // Directional resize (grow/shrink-window-*): moves ONE edge of the
    // focused pane by one step (cell when measurable, else
    // resize-step-points), opposite edge anchored. Grow shoves blockers
    // out of the way along that axis (chained) when overlap is
    // disallowed; shrink never moves others. Minimum 160x120, same as
    // mouse resize. Persists every touched pane via movePane; the
    // focused pane's PTY reflows via setRect(notifySurface:).
    func resizeFocused(edge: GCTNewWindowDirection, grow: Bool) {
        guard let id = focusedID, let pane = panes[id] else { return }
        let cfg = GCTConfig.current
        let f = pane.frame
        let step: CGFloat = {
            if let cell = cellSize, cell.width > 0, cell.height > 0 {
                let base = edge == .left || edge == .right
                    ? cell.width : cell.height
                return base * CGFloat(cfg.resizeStepCells)
            }
            return cfg.resizeStepPoints
        }()
        let minW: CGFloat = 160, minH: CGFloat = 120
        var rect = f
        switch (edge, grow) {
        case (.right, true): rect.size.width = f.width + step
        case (.right, false): rect.size.width = max(minW, f.width - step)
        case (.left, true):
            rect.origin.x = f.minX - step
            rect.size.width = f.width + step
        case (.left, false):
            let w = max(minW, f.width - step)
            rect.origin.x = f.maxX - w
            rect.size.width = w
        case (.above, true): rect.size.height = f.height + step
        case (.above, false): rect.size.height = max(minH, f.height - step)
        case (.below, true):
            rect.origin.y = f.minY - step
            rect.size.height = f.height + step
        case (.below, false):
            let h = max(minH, f.height - step)
            rect.origin.y = f.maxY - h
            rect.size.height = h
        }
        guard rect != f else { return }
        let memberOf: Set<GroupID> = groupOf(id).map { Set([$0]) } ?? []
        if grow, !cfg.allowWindowOverlap {
            let (axis, sign): (Overlap.Axis, Int) = switch edge {
            case .right: (.horizontal, 1)
            case .left: (.horizontal, -1)
            case .above: (.vertical, 1)
            case .below: (.vertical, -1)
            }
            shoveForGrow(candidate: NSRectOverlap.from(rect),
                         moving: id, axis: axis, sign: sign)
        } else if !cfg.allowWindowOverlap || groupOf(id) != nil {
            // Shrink (and any grouped grow with overlap allowed): clamp
            // against the shared policy. Group bounds always block;
            // members additionally avoid loose panes.
            let obstacles = GroupLayout.moveObstacles(
                moving: id, memberOf: memberOf, panes: paneRects(),
                groups: groupMetas, allowOverlap: cfg.allowWindowOverlap,
                floating: floatingPanes())
            if !cfg.allowWindowOverlap || !obstacles.isEmpty {
                let clean = Overlap.clampResize(
                    NSRectOverlap.from(rect),
                    original: NSRectOverlap.from(f),
                    edges: Overlap.Edges(
                        w: edge == .left, e: edge == .right,
                        s: edge == .below, n: edge == .above),
                    obstacles: obstacles)
                rect = NSRectOverlap.to(clean)
                guard rect != f else { return }
            }
            // Members: foreigners in the grown path shove aside along the
            // resize axis (persisted immediately). Unresolvable → hold.
            if let memberOf = groupOf(id) {
                let ax: (Overlap.Axis, Int) = switch edge {
                case .right: (.horizontal, 1)
                case .left: (.horizontal, -1)
                case .above: (.vertical, 1)
                case .below: (.vertical, -1)
                }
                let ok = shoveForeignForMember(
                    id: id, memberOf: memberOf,
                    candidate: NSRectOverlap.from(rect), from: pane.frame,
                    axis: ax)
                guard ok else { return }
            }
        }
        pane.setRect(rect, notifySurface: true)
        conn?.movePane(MovePane(id: id, rect: Rect(
            x: rect.minX, y: rect.minY, w: rect.width, h: rect.height),
            allowOverlap: GCTConfig.current.allowWindowOverlap))
        refreshGroupViews()
        refreshOcclusion()
    }

    // Keyboard grow-shove along one axis: push blockers out of the way.
    // Foreign groups move as RIGID BLOCKS (every member by the same
    // delta); lone panes move individually. Every touched pane persists
    // via movePane (notifySurface false — size unchanged).
    private func shoveForGrow(candidate: Rect, moving: PaneID,
                              axis: Overlap.Axis, sign: Int) {
        let memberOf: Set<GroupID> = groupOf(moving).map { Set([$0]) } ?? []
        let rects = paneRects()
        // Push grown bounds (padding counts as exclusion), not just the
        // member frame.
        let grown: Rect
        if let memberOf = groupOf(moving),
           let g = GroupLayout.grownRect(moving: moving, memberOf: memberOf,
                                         candidate: candidate,
                                         panes: rects, groups: groupMetas) {
            grown = g
        } else {
            grown = candidate
        }
        let moves = GroupLayout.shoveAside(
            grown: grown, moving: moving, memberOf: memberOf,
            panes: rects, groups: groupMetas,
            axis: axis, sign: sign,
            allowOverlap: GCTConfig.current.allowWindowOverlap,
            floating: floatingPanes())
        for (pid, r) in moves {
            guard let pane = panes[pid], pane.id != moving else { continue }
            let frame = NSRectOverlap.to(r)
            guard frame != pane.frame else { continue }
            pane.setRect(frame, notifySurface: false)
            conn?.movePane(MovePane(id: pid, rect: r,
                    allowOverlap: GCTConfig.current.allowWindowOverlap))
        }
        refreshGroupViews()
        refreshOcclusion()
    }

    // MARK: Camera actions

    // Directional focus move (cmd+h/j/k/l): focus the nearest pane in
    // the given direction from the focused pane. Candidates must overlap
    // the focused pane on the perpendicular axis (like a tiling WM: only
    // panes actually in that direction count); the nearest wins by gap
    // between facing edges, ties broken by less perpendicular drift.
    // Camera: zoom-to-fit when camera-fits-focus-move, else recenter at
    // the current scale when camera-follows-focus-move.
    func moveFocus(_ dir: GCTNewWindowDirection) {
        guard let focused = focusedID.flatMap({ panes[$0] }) else { return }
        let f = focused.frame
        let fcx = f.midX, fcy = f.midY
        var best: (id: PaneID, gap: CGFloat, drift: CGFloat)?
        for (id, pane) in panes where id != focused.id {
            let r = pane.frame
            let gap: CGFloat
            let drift: CGFloat
            switch dir {
            case .left:
                guard r.maxX <= f.minX + 0.5, r.maxY > f.minY, r.minY < f.maxY else { continue }
                gap = f.minX - r.maxX
                drift = abs(r.midY - fcy)
            case .right:
                guard r.minX >= f.maxX - 0.5, r.maxY > f.minY, r.minY < f.maxY else { continue }
                gap = r.minX - f.maxX
                drift = abs(r.midY - fcy)
            case .above:
                guard r.minY >= f.maxY - 0.5, r.maxX > f.minX, r.minX < f.maxX else { continue }
                gap = r.minY - f.maxY
                drift = abs(r.midX - fcx)
            case .below:
                guard r.maxY <= f.minY + 0.5, r.maxX > f.minX, r.minX < f.maxX else { continue }
                gap = f.minY - r.maxY
                drift = abs(r.midX - fcx)
            }
            if let b = best, (gap, drift) >= (b.gap, b.drift) { continue }
            best = (id, gap, drift)
        }
        guard let target = best?.id else { return }
        focusPane(target)
        let cfg = GCTConfig.current
        if cfg.cameraFitsFocusMove {
            zoomToPane(target)
        } else if cfg.cameraFollowsFocusMove {
            centerOnPane(target)
        }
    }

    // Recenter the camera on a pane without changing the zoom.
    func centerOnPane(_ id: PaneID) {
        guard let pane = panes[id], let window else { return }
        let screen = window.frame.size
        let r = pane.frame
        animateCamera(to: Camera(
            offset: CGPoint(x: screen.width / 2 - r.midX * camera.scale,
                            y: screen.height / 2 - r.midY * camera.scale),
            scale: camera.scale))
    }

    func zoomToPane(_ id: PaneID) {
        guard let pane = panes[id], let window else { return }
        let screen = window.frame.size
        let r = pane.frame
        let fit = min(CGFloat(0.8) * screen.width / r.width,
                      CGFloat(0.8) * screen.height / r.height,
                      Camera.maxScale)
        animateCamera(to: Camera(
            offset: CGPoint(x: screen.width / 2 - r.midX * fit,
                            y: screen.height / 2 - r.midY * fit),
            scale: fit))
    }

    func fitAll() {
        guard !zOrder.isEmpty, let window else { return }
        var bbox = CGRect.null
        for pane in panes.values { bbox = bbox.union(pane.frame) }
        let screen = window.frame.size
        let fit = min(screen.width / bbox.width,
                      screen.height / bbox.height,
                      Camera.maxScale) * 0.92
        animateCamera(to: Camera(
            offset: CGPoint(x: screen.width / 2 - bbox.midX * fit,
                            y: screen.height / 2 - bbox.midY * fit),
            scale: fit))
    }

    private var cameraAnim: (Timer, Camera, Camera, Double)?

    func animateCamera(to target: Camera) {
        cameraAnim?.0.invalidate()
        let from = camera
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.stepCamera()
        }
        RunLoop.main.add(timer, forMode: .common)
        cameraAnim = (timer, from, target, CACurrentMediaTime())
    }

    private func stepCamera() {
        guard let anim = cameraAnim else { return }
        let t = min((CACurrentMediaTime() - anim.3) / 0.28, 1)
        let ease = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        camera = Camera(
            offset: CGPoint(x: anim.1.offset.x + (anim.2.offset.x - anim.1.offset.x) * ease,
                            y: anim.1.offset.y + (anim.2.offset.y - anim.1.offset.y) * ease),
            scale: anim.1.scale + (anim.2.scale - anim.1.scale) * ease)
        applyCamera()
        if t >= 1 {
            anim.0.invalidate()
            cameraAnim = nil
        }
    }

    // MARK: Switcher

    func toggleSwitcher() {
        dropComposition()
        if let switcher {
            switcher.dismiss()
            window?.makeFirstResponder(self)
            return
        }
        let s = SwitcherView(frame: NSRect(x: bounds.midX - 320, y: bounds.midY - 240,
                                           width: 640, height: 480))
        s.onSelect = { [weak self] id in
            self?.focusPane(id)
            let cfg = GCTConfig.current
            if cfg.cameraFitsFocusMove {
                self?.zoomToPane(id)
            } else if cfg.cameraFollowsFocusMove {
                self?.centerOnPane(id)
            }
        }
        s.onDismiss = { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
        addSubview(s)
        switcher = s
        s.present(panes.values.map(\.meta), order: zOrder)
        // Keep the bar on its own topmost layer, above the switcher.
        if let bar = statusBar, bar.superview != nil { addSubview(bar) }
    }
}

// MARK: Resize zones as flags

extension PaneView.ResizeZone {
    var resizesW: Bool {
        switch self { case .w, .nw, .sw: return true; default: return false }
    }
    var resizesE: Bool {
        switch self { case .e, .ne, .se: return true; default: return false }
    }
    var resizesS: Bool {
        switch self { case .s, .sw, .se: return true; default: return false }
    }
    var resizesN: Bool {
        switch self { case .n, .nw, .ne: return true; default: return false }
    }
}


// MARK: NSRect bridge over Common.Overlap (pure Rect math, shared with gctd).
// Local drags/resizes resolve live under the cursor; daemon moves arrive
// pre-resolved. Both read the same geometry.
enum NSRectOverlap {
    static func from(_ r: NSRect) -> Rect {
        Rect(x: r.minX, y: r.minY, w: r.width, h: r.height)
    }
    static func to(_ r: Rect) -> NSRect {
        NSRect(x: r.x, y: r.y, width: r.w, height: r.h)
    }
    static func frames(of panes: [PaneID: PaneView], except id: PaneID) -> [Rect] {
        panes.values.filter { $0.id != id }.map { from($0.frame) }
    }
}

// MARK: Shared paths

enum CanvasPaths {
    static let supportDir = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/Grand Central Terminal")
    static let sockPath = supportDir + "/daemon.sock"
    static let daemonPath = supportDir + "/bin/gctd"
}

// MARK: - NSTextInputClient
// Conformance is what makes the text input system route dead keys and IMEs
// through this view while it is first responder.

extension CanvasView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        guard let host = focusedHost,
              let surface = host.surfaceIfOpen(),
              ghostty_surface_has_selection(surface) else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break
        }

        if markedText.length > 0, markedHost == nil {
            markedHost = focusedHost
        }

        // Outside a keyDown (e.g. the keyboard layout changed mid-composition)
        // update the preedit immediately; inside keyDown the caller does it.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
        markedHost = nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // We must have an associated event.
        guard NSApp.currentEvent != nil else { return }

        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as NSString:
            // Korean IMEs can deliver a surrogate pair as two separate
            // insertText calls; buffer the lead half until the trail lands.
            if let lead = LeadSurrogate(v) {
                pendingLeadSurrogate = lead
                return
            }
            if let trail = TrailSurrogate(v) {
                chars = pendingLeadSurrogate?.encode(trail: trail) ?? ""
                pendingLeadSurrogate = nil
            } else {
                chars = v as String
                pendingLeadSurrogate = nil
            }
        default:
            return
        }

        // insertText ends any in-progress composition.
        unmarkText()

        // Inside a keyDown we just accumulate; keyDown sends it.
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        // Committed text outside a key event is still typed input, so it
        // must go through as a key event, never as a paste.
        if !chars.isEmpty, let host = focusedHost {
            _ = committedTextAction(GHOSTTY_ACTION_PRESS, text: chars, to: host)
        }
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window,
              let id = focusedID, let pane = panes[id], let host = pane.host,
              let pt = host.imePoint() else {
            return .zero
        }

        var x = pt.x
        let y = pt.y
        var w = pt.width
        let h = pt.height

        // Dictation wants a point, not a rect.
        if range.length == 0, w > 0 {
            w = 0
            x += pt.width * Double(range.location)
        }

        // ghostty coordinates are top-left origin; AppKit is bottom-left.
        let hostHeight = pane.surfaceHostView.bounds.height
        let viewRect = NSRect(x: x, y: hostHeight - y, width: w, height: max(h, 0))

        // View geometry ignores the camera sublayerTransform, so convert
        // host -> world with AppKit, then apply the camera by hand.
        let worldRect = pane.surfaceHostView.convert(viewRect, to: worldView)
        let canvasRect = NSRect(
            origin: camera.worldToScreen(worldRect.origin),
            size: NSSize(width: worldRect.width * camera.scale,
                         height: worldRect.height * camera.scale))

        let winRect = convert(canvasRect, to: nil)
        return window.convertToScreen(winRect)
    }
}
