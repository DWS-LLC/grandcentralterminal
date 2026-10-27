// Arrange By: one-shot tidy of panes, Finder "Clean Up By" style.
//
//   scope ──► units ──► sort ──► pack ──► nudge clear ──► place
//
//   scope   selection | one group's members | the whole canvas
//   units   a loose pane, or a whole group (rigid block)
//   pack    ArrangeEngine (Common): rows / columns / grid
//   place   local frames now + one atomic arrangePanes per daemon
//
// Relax is the same pipeline with springs for the pack step: related
// units pull together, strangers push apart (Common/Spring).
//
// Nothing here is live: the layout is solved once and panes stay free
// afterwards. Every run is undoable (ArrangeState.undo).

import AppKit
import Common

enum ArrangeKey: String, CaseIterable {
    case position, name, directory, status, focus, activity

    var title: String {
        switch self {
        case .position: "Clean Up"
        case .name: "Name"
        case .directory: "Directory"
        case .status: "Status"
        case .focus: "Last Focused"
        case .activity: "Activity"
        }
    }
}

extension ArrangeShape {
    var title: String {
        switch self {
        case .rows: "Rows"
        case .columns: "Columns"
        case .grid: "Grid"
        }
    }
}

enum ArrangeScope {
    case auto            // resolved at fire time: selection > focused group > all
    case all
    case selection
    case group(GroupID)
}

// What a menu item asks for: change one axis, then arrange.
struct ArrangeAction {
    enum Change {
        case key(ArrangeKey)
        case shape(ArrangeShape)
    }
    var change: Change
    var scope: ArrangeScope
}

// One arrange run: where panes were, and where the run put them. Undo
// only trusts panes still sitting at `after`.
struct ArrangeUndo {
    var before: [PaneRect]
    var after: [PaneRect]
}

// Per-canvas memory: last choices, undo stack, and the focus/output
// clocks the Last Focused / Activity keys sort on.
final class ArrangeState {
    private static let undoDepth = 10
    // Output within this long of a keystroke is echo, not work.
    private static let echoWindow: CFAbsoluteTime = 0.3
    // Coarser than any human-visible difference; spares the hot path.
    private static let outputResolution: CFAbsoluteTime = 1

    var key: ArrangeKey = .name
    var shape: ArrangeShape = .rows
    private(set) var undo = [ArrangeUndo]()
    let glide = PaneGlide()

    private var focusClock: UInt64 = 0
    private var focusStamp = [PaneID: UInt64]()
    private var lastOutput = [PaneID: CFAbsoluteTime]()
    private var lastInput = [PaneID: CFAbsoluteTime]()

    func noteFocus(_ id: PaneID) {
        focusClock += 1
        focusStamp[id] = focusClock
    }

    func noteInput(_ id: PaneID) {
        lastInput[id] = CFAbsoluteTimeGetCurrent()
    }

    // Hot path: every live chunk lands here.
    func noteOutput(_ id: PaneID) {
        let now = CFAbsoluteTimeGetCurrent()
        if let typed = lastInput[id], now - typed < Self.echoWindow { return }
        if let last = lastOutput[id], now - last < Self.outputResolution { return }
        lastOutput[id] = now
    }

    func forget(_ id: PaneID) {
        focusStamp.removeValue(forKey: id)
        lastOutput.removeValue(forKey: id)
        lastInput.removeValue(forKey: id)
    }

    func focusRank(_ id: PaneID) -> Double { Double(focusStamp[id] ?? 0) }
    func outputRank(_ id: PaneID) -> Double { lastOutput[id] ?? 0 }

    func pushUndo(_ entry: ArrangeUndo) {
        undo.append(entry)
        if undo.count > Self.undoDepth { undo.removeFirst() }
    }

    func popUndo() -> ArrangeUndo? { undo.popLast() }
}

// A loose pane, or a group moving as one block (frame = its grown bounds).
private struct ArrangeUnit {
    var panes: [PaneID]
    var group: GroupID?
    var frame: Rect
}

extension CanvasView {
    // MARK: Entry points

    // False when refused (beeps); true when it ran, even if nothing moved.
    @discardableResult
    func arrangeCanvas(scope: ArrangeScope) -> Bool {
        arrange.glide.finish()

        // A zoomed pane's frame is local-only until unzoom.
        guard zoomSavedPane == nil else { NSSound.beep(); return false }

        let rects = paneRects()
        let resolved = resolveArrangeScope(scope)
        let units = arrangeUnits(resolved, rects: rects)
        guard units.count >= 2 else { NSSound.beep(); return false }

        let ordered = sortedUnits(units, by: arrange.key)
        let moves = solveArrange(ordered, scope: resolved, rects: rects)
        guard !moves.isEmpty else { return true }

        let before = moves.compactMap { m in rects[m.id].map { PaneRect(id: m.id, rect: $0) } }
        arrange.pushUndo(ArrangeUndo(before: before, after: moves))
        placePanes(moves)
        return true
    }

    // All or nothing: a pane moved, closed, or a newcomer sitting in an
    // old spot makes the snapshot stale, and a stale restore would stack
    // panes on each other.
    func undoArrange() {
        arrange.glide.finish()
        guard let entry = arrange.popUndo(), undoIsFresh(entry) else { NSSound.beep(); return }
        placePanes(entry.before)
    }

    private func undoIsFresh(_ entry: ArrangeUndo) -> Bool {
        let rects = paneRects()
        let touched = Set(entry.after.map(\.id))

        for m in entry.after where rects[m.id] != m.rect { return false }

        let others = rects.filter { !touched.contains($0.key) }.map(\.value)
        for m in entry.before {
            if others.contains(where: { Overlap.overlaps(m.rect, $0) }) { return false }
        }
        return true
    }

    func resolveArrangeScope(_ scope: ArrangeScope) -> ArrangeScope {
        guard case .auto = scope else { return scope }
        if !liveSelected().isEmpty { return .selection }
        if let f = focusedID, let g = groupOf(f) { return .group(g) }
        return .all
    }

    // MARK: Units

    private func arrangeUnits(_ scope: ArrangeScope, rects: [PaneID: Rect]) -> [ArrangeUnit] {
        switch scope {
        case .group(let gid):
            let members = groupMetas[gid]?.members ?? []
            return members.compactMap { id in
                rects[id].map { ArrangeUnit(panes: [id], group: nil, frame: $0) }
            }
        case .selection:
            return blockUnits(Set(liveSelected()), rects: rects)
        case .all, .auto:
            return blockUnits(Set(rects.keys), rects: rects)
        }
    }

    // Groups fully inside `ids` move as one block, loose panes alone. A
    // group only partly inside stays put: moving some members would tear it.
    private func blockUnits(_ ids: Set<PaneID>, rects: [PaneID: Rect]) -> [ArrangeUnit] {
        var out = [ArrangeUnit]()
        var grouped = Set<PaneID>()

        for (gid, meta) in groupMetas {
            let live = meta.members.filter { rects[$0] != nil }
            grouped.formUnion(live)
            guard !live.isEmpty, live.allSatisfy(ids.contains),
                  let bounds = GroupGeometry.bounds(frames: live.compactMap { rects[$0] })
            else { continue }
            out.append(ArrangeUnit(panes: live, group: gid, frame: bounds))
        }

        for id in ids where !grouped.contains(id) {
            guard let r = rects[id] else { continue }
            out.append(ArrangeUnit(panes: [id], group: nil, frame: r))
        }
        return out
    }

    // MARK: Order

    // Top-to-bottom rows (a row = tops within half a pane height), left to
    // right inside each. The base order every key falls back on.
    // A row = tops within this fraction of the first unit's height.
    private static let rowTolerance = 0.5

    private func readingOrder(_ units: [ArrangeUnit]) -> [ArrangeUnit] {
        let byTop = units.sorted { ($0.frame.y + $0.frame.h) > ($1.frame.y + $1.frame.h) }
        var rows = [[ArrangeUnit]]()
        for u in byTop {
            let top = u.frame.y + u.frame.h
            if let first = rows.last?.first,
               first.frame.y + first.frame.h - top <= first.frame.h * Self.rowTolerance {
                rows[rows.count - 1].append(u)
                continue
            }
            rows.append([u])
        }
        return rows.flatMap { $0.sorted { $0.frame.x < $1.frame.x } }
    }

    private func sortedUnits(_ units: [ArrangeUnit], by key: ArrangeKey) -> [ArrangeUnit] {
        let base = readingOrder(units)
        guard key != .position else { return base }

        let ranked = base.enumerated().map { (idx: $0.offset, unit: $0.element, rank: rank($0.element, key)) }
        let sorted = ranked.sorted { a, b in
            let order = a.rank.text.localizedStandardCompare(b.rank.text)
            if order != .orderedSame { return order == .orderedAscending }
            if a.rank.num != b.rank.num { return a.rank.num < b.rank.num }
            return a.idx < b.idx
        }
        return sorted.map(\.unit)
    }

    // Text keys sort ascending; numeric keys are negated so the biggest
    // (most recent, most urgent) comes first.
    private func rank(_ u: ArrangeUnit, _ key: ArrangeKey) -> (text: String, num: Double) {
        let first = u.panes.first.flatMap { panes[$0] }
        switch key {
        case .position:
            return ("", 0)
        case .name:
            if let g = u.group, let name = groupMetas[g]?.name { return (name, 0) }
            return (first.map(arrangeLabel) ?? "", 0)
        case .directory:
            let host = first.flatMap { hub.owner(of: $0.id) } ?? "local"
            return (host + (first?.meta.cwd ?? ""), 0)
        case .status:
            let best = u.panes.map { statusPriority(panes[$0]?.programStatus?.state) }.min() ?? 0
            return ("", Double(best))
        case .focus:
            return ("", -(u.panes.map(arrange.focusRank).max() ?? 0))
        case .activity:
            return ("", -(u.panes.map(arrange.outputRank).max() ?? 0))
        }
    }

    private func arrangeLabel(_ pane: PaneView) -> String {
        pane.displayName
    }

    // Needs-attention first; panes that report nothing last.
    private static let statusOrder: [ProgramState?] = [.blocked, .error, .working, .done, .idle, nil]

    private func statusPriority(_ state: ProgramState?) -> Int {
        Self.statusOrder.firstIndex(of: state) ?? Self.statusOrder.count
    }

    // MARK: Solve

    // Pack, anchor at the old bounds' top-left, nudge the whole result
    // clear of everything that isn't moving, then fan units back out to
    // per-pane rects. Only panes whose rect changed come back.
    private func solveArrange(_ units: [ArrangeUnit], scope: ArrangeScope,
                              rects: [PaneID: Rect]) -> [PaneRect] {
        guard let old = ArrangeEngine.bounds(units.map(\.frame)) else { return [] }

        var sizes = units.map { ArrangeSize(w: $0.frame.w, h: $0.frame.h) }
        if arrange.shape == .grid {
            normalize(&sizes, units: units)
        }

        let limit = arrangeLimit(sizes, old: old, scope: scope)
        let gap = Double(GCTConfig.current.windowGap)
        let layout = ArrangeEngine.pack(sizes, shape: arrange.shape, limit: limit, gap: gap)

        // Layout space is y-down from the old top-left; the canvas is y-up.
        let top = old.y + old.h
        let frames = layout.map { Rect(x: old.x + $0.x, y: top - $0.y - $0.h, w: $0.w, h: $0.h) }
        let placed = clearance(of: frames, scope: scope, moving: Set(units.flatMap(\.panes)),
                               rects: rects, gap: gap)

        return fanOut(units, placed, rects: rects)
    }

    // Unit frames back to per-pane rects; a group block shifts its members
    // rigidly. Only panes whose rect changed come back.
    private func fanOut(_ units: [ArrangeUnit], _ placed: [Rect],
                        rects: [PaneID: Rect]) -> [PaneRect] {
        var out = [PaneRect]()
        for (u, f) in zip(units, placed) {
            let dx = f.x - u.frame.x
            let dy = f.y - u.frame.y
            for id in u.panes {
                guard let r = rects[id] else { continue }
                let target = u.group == nil
                    ? f
                    : Rect(x: r.x + dx, y: r.y + dy, w: r.w, h: r.h)
                if target != r { out.append(PaneRect(id: id, rect: target)) }
            }
        }
        return out
    }

    // Grid cells are uniform: loose panes snap to the median size, group
    // blocks keep theirs (a block is a layout, not a cell).
    private func normalize(_ sizes: inout [ArrangeSize], units: [ArrangeUnit]) {
        let loose = units.indices.filter { units[$0].group == nil }
        guard let med = ArrangeEngine.median(loose.map { sizes[$0] }) else { return }
        for i in loose { sizes[i] = med }
    }

    // Rows wrap at the visible width (one group: its own width), never
    // narrower than the widest unit.
    private func arrangeLimit(_ sizes: [ArrangeSize], old: Rect, scope: ArrangeScope) -> ArrangeSize {
        var limit = ArrangeSize(w: Double(camera.screenToWorldDistance(bounds.width)),
                                h: Double(camera.screenToWorldDistance(bounds.height)))
        if case .group = scope {
            limit = ArrangeSize(w: old.w, h: old.h)
        }
        limit.w = max(limit.w, sizes.map(\.w).max() ?? 0)
        limit.h = max(limit.h, sizes.map(\.h).max() ?? 0)
        return limit
    }

    // Frames moved clear of panes and groups staying put. Floating panes
    // are allowed to overlap, so they never block.
    //
    //   group scope   one rigid shift of the grown group bounds: the
    //                 members must stay a layout, and the frame the
    //                 neighbours see is the padded one, not the raw panes
    //   otherwise     each unit dodges on its own, so one stray pane in
    //                 the middle doesn't shove the whole arrangement
    private func clearance(of frames: [Rect], scope: ArrangeScope, moving: Set<PaneID>,
                           rects: [PaneID: Rect], gap: Double) -> [Rect] {
        var obstacles = staying(moving: moving, rects: rects)

        if case .group = scope {
            guard let grown = GroupGeometry.bounds(frames: frames) else { return frames }
            let clean = Overlap.resolve(grown, obstacles: obstacles, gap: gap)
            let dx = clean.x - grown.x, dy = clean.y - grown.y
            return frames.map { Rect(x: $0.x + dx, y: $0.y + dy, w: $0.w, h: $0.h) }
        }

        var out = [Rect]()
        for f in frames {
            let clean = Overlap.resolve(f, obstacles: obstacles, gap: gap)
            out.append(clean)
            obstacles.append(clean)
        }
        return out
    }

    // Panes and group bounds that stay put while `moving` is rearranged.
    private func staying(moving: Set<PaneID>, rects: [PaneID: Rect]) -> [Rect] {
        let floating = floatingPanes()
        var out = rects.filter { !moving.contains($0.key) && !floating.contains($0.key) }
            .map(\.value)
        for (gid, b) in GroupLayout.bounds(groups: groupMetas, panes: rects) {
            let members = groupMetas[gid]?.members ?? []
            if members.contains(where: { !moving.contains($0) }) { out.append(b) }
        }
        return out
    }

    // MARK: Relax

    // A left-to-right tree of the cables instead of a pack: a pane sits right
    // of the pane that spawned it, siblings stack in order (top to bottom,
    // left to right, id as the last word), so the same canvas always
    // relaxes the same way. False when refused (beeps).
    @discardableResult
    func relaxCanvas(scope: ArrangeScope) -> Bool {
        arrange.glide.finish()

        guard zoomSavedPane == nil else { NSSound.beep(); return false }

        let rects = paneRects()
        let resolved = resolveArrangeScope(scope)
        let units = arrangeUnits(resolved, rects: rects).sorted(by: Self.stableOrder)
        guard units.count >= 2 else { NSSound.beep(); return false }

        let moves = solveRelax(units, scope: resolved, rects: rects)
        guard !moves.isEmpty else { return true }

        let before = moves.compactMap { m in rects[m.id].map { PaneRect(id: m.id, rect: $0) } }
        arrange.pushUndo(ArrangeUndo(before: before, after: moves))
        placePanes(moves, mode: .glide)
        return true
    }

    private static func stableOrder(_ a: ArrangeUnit, _ b: ArrangeUnit) -> Bool {
        let (ta, tb) = (a.frame.y + a.frame.h, b.frame.y + b.frame.h)
        if ta != tb { return ta > tb }
        if a.frame.x != b.frame.x { return a.frame.x < b.frame.x }
        return (a.panes.first?.description ?? "") < (b.panes.first?.description ?? "")
    }

    // Spacing between tree columns and rows is never tighter than this,
    // however small `window-gap` is: cables need room to bundle.
    private static let minTreeGap = 48.0

    private func solveRelax(_ units: [ArrangeUnit], scope: ArrangeScope,
                            rects: [PaneID: Rect]) -> [PaneRect] {
        let parents = unitParents(units)
        let moving = Set(units.flatMap(\.panes))
        let gap = Double(GCTConfig.current.windowGap)
        let solved = TreeLayout.place(units.map(\.frame), parents: parents,
                                      gap: max(gap, Self.minTreeGap))
        let placed = clearance(of: solved, scope: scope, moving: moving, rects: rects, gap: gap)
        return fanOut(units, placed, rects: rects)
    }

    // The unit holding the pane that spawned any pane of the unit (the
    // first such unit if several). Nil for a unit nothing in scope spawned.
    private func unitParents(_ units: [ArrangeUnit]) -> [Int?] {
        var unitOf = [PaneID: Int]()
        for (i, u) in units.enumerated() {
            for id in u.panes { unitOf[id] = i }
        }

        return units.enumerated().map { i, u in
            u.panes.compactMap { panes[$0]?.meta.parent.flatMap { unitOf[$0] } }
                .filter { $0 != i }.min()
        }
    }

    // MARK: Place

    private enum PlaceMode {
        case snap
        case glide
    }

    private func placePanes(_ moves: [PaneRect], mode: PlaceMode = .snap) {
        let live = moves.filter { panes[$0.id] != nil }
        switch mode {
        case .snap: land(live)
        case .glide: glide(live)
        }
    }

    private func land(_ live: [PaneRect]) {
        for m in live {
            panes[m.id]?.setRect(NSRectOverlap.to(m.rect), notifySurface: true)
        }
        hub.arrangePanes(live)
        refreshGroupViews()
        refreshOcclusion()
    }

    // Ease frames over the camera animation time; terminals and the
    // daemon only hear about it on land.
    private func glide(_ live: [PaneRect]) {
        let steps = live.compactMap { m in
            panes[m.id].map { GlideStep(id: m.id, from: NSRectOverlap.from($0.frame), to: m.rect) }
        }
        let secs = GCTConfig.current.cameraAnimDuration

        arrange.glide.run(steps, duration: secs) { [weak self] rects, phase in
            guard let self else { return }
            if phase == .land {
                land(rects.filter { self.panes[$0.id] != nil })
                return
            }

            for r in rects {
                panes[r.id]?.setRect(NSRectOverlap.to(r.rect), notifySurface: false)
            }
            refreshGroupViews()
            refreshOcclusion()
        }
    }
}
