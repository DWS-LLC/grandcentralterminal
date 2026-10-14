// Canvas-side terminal-group state: metas from the daemon, background
// views under the panes, rubber-band selection, and shared geometry
// over live pane frames. The daemon owns membership truth; this file
// owns the local view of it between broadcasts.

import AppKit
import Common

extension CanvasView {
    // MARK: Group state (main thread only)

    // All panes current group membership: ids the daemon lists in groups.
    func groupOf(_ id: PaneID) -> GroupID? {
        groupMetas.first { $0.value.members.contains(id) }?.key
    }

    func paneRects() -> [PaneID: Rect] {
        var out = [PaneID: Rect]()
        for (id, p) in panes { out[id] = NSRectOverlap.from(p.frame) }
        return out
    }

    func groupMetasByID() -> [GroupID: GroupMeta] { groupMetas }

    // Live group rectangle from current pane frames (union + padding).
    func groupBounds(_ id: GroupID) -> NSRect? {
        guard let g = groupMetas[id] else { return nil }
        let frames = g.members.compactMap { panes[$0]?.frame }
            .map { NSRectOverlap.from($0) }
        guard let b = GroupGeometry.bounds(frames: frames) else { return nil }
        return NSRectOverlap.to(b)
    }

    func ensureGroupView(_ id: GroupID) {
        guard groupViews[id] == nil else { return }
        let v = GroupView(id: id)
        groupViews[id] = v
        // Below every pane: groups are background.
        worldView.addSubview(v, positioned: .below, relativeTo: nil)
    }

    // Recompute every background rect from live frames + metas. Called
    // after pane create/move/resize/exit and group create/update/exit.
    func refreshGroupViews() {
        let rects = paneRects()
        let live = GroupLayout.bounds(groups: groupMetas, panes: rects)
        for (id, meta) in groupMetas {
            ensureGroupView(id)
            guard let view = groupViews[id] else { continue }
            if let b = live[id] {
                view.update(bounds: NSRectOverlap.to(b),
                            name: meta.name, colorHex: meta.color)
            } else {
                view.update(bounds: nil, name: meta.name,
                            colorHex: meta.color)
            }
        }
        // Panes always above group backgrounds; floating panes above
        // every tiled pane.
        for view in groupViews.values { view.removeFromSuperview() }
        for (id, view) in groupViews {
            guard groupMetas[id] != nil else { continue }
            worldView.addSubview(view, positioned: .below, relativeTo: nil)
        }
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

    func topGroup(at worldPoint: CGPoint) -> GroupView? {
        // Frontmost = last touched; zOrder of panes approximates it.
        // Walk groups in reverse creation order (dict order is stable
        // enough for a tiebreak here; overlapping groups are an edge).
        // A zoomed pane fills the viewport above everything: skip group
        // backgrounds while zoomed so empty-area clicks can't grab the
        // group hiding underneath it.
        if zoomSavedPane != nil { return nil }
        for view in groupViews.values.reversed() {
            if view.containsWorld(worldPoint) { return view }
        }
        return nil
    }

    // MARK: Group membership mutations (daemon round-trip)

    func createGroup(members: [PaneID], name: String? = nil) {
        guard !members.isEmpty else { return }
        // Same-host only: a group arbitrates layout on ONE daemon.
        // Mixed selections group their largest same-host subset; a 1/1
        // split across hosts refuses (nothing to group). Single-pane
        // groups are allowed (named pin for later adds via titlebar).
        let byOwner = Dictionary(grouping: members, by: { hub.owner(of: $0) ?? "local" })
        guard let (owner, owned) = byOwner.max(by: { $0.value.count < $1.value.count }),
              !owned.isEmpty else { return }
        if owned.count < members.count {
            NSLog("[gct] group: mixed-host selection — grouping the \(owned.count) \(owner) panes")
        }
        let color = GroupStyle.palette[groupMetas.count % GroupStyle.palette.count]
        hub.createGroup(CreateGroup(name: name, color: color,
                                    members: owned), owner: owner)
    }

    func ungroup(_ id: GroupID) {
        hub.deleteGroup(id)
    }

    func renameGroup(_ id: GroupID, name: String?) {
        guard var g = groupMetas[id] else { return }
        g.name = GroupStyle.sanitizedName(name)
        groupMetas[id] = g
        refreshGroupViews()
        hub.updateGroup(UpdateGroup(id: id, name: g.name,
                                      color: g.color, members: g.members))
    }

    func setGroupMembers(_ id: GroupID, members: [PaneID]) {
        guard var g = groupMetas[id] else { return }
        g.members = members
        groupMetas[id] = g
        refreshGroupViews()
        hub.updateGroup(UpdateGroup(id: id, name: g.name,
                                      color: g.color, members: g.members))
    }

    // MARK: Rubber-band selection

    func showSelectionBand() {
        guard let band = selectionBand else { return }
        let rect = selectionRect(band)
        if selectionView == nil {
            let v = NSView(frame: rect)
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
            v.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
            v.layer?.borderWidth = 1
            selectionView = v
            worldView.addSubview(v)
        }
        selectionView?.frame = rect
    }

    func hideSelectionBand() {
        selectionView?.removeFromSuperview()
        selectionView = nil
        selectionBand = nil
    }

    func selectionRect(_ band: (anchor: CGPoint, current: CGPoint)) -> NSRect {
        NSRect(x: min(band.anchor.x, band.current.x),
               y: min(band.anchor.y, band.current.y),
               width: abs(band.current.x - band.anchor.x),
               height: abs(band.current.y - band.anchor.y))
    }

    // Panes fully inside the finished band (titlebar included). Stages
    // a multi-selection WITHOUT grouping: right-click acts on it (group
    // / close / clear), the group keybind groups it, dragging a member
    // moves the whole block.
    func finishSelectionBand() {
        guard let band = selectionBand else { return }
        let rect = selectionRect(band)
        // Same 8-screen-point click-vs-drag rule as rightMouseUp.
        guard camera.worldToScreenDistance(rect.width) > 8,
              camera.worldToScreenDistance(rect.height) > 8 else { return }
        var picked = [PaneID]()
        for (id, pane) in panes where rect.contains(pane.frame) {
            picked.append(id)
        }
        guard !picked.isEmpty else { return }
        setSelected(Set(picked))
    }

    // MARK: Multi-select (staged, no daemon group)

    // Live members (drop panes that exited since staging).
    func liveSelected() -> [PaneID] {
        selectedIDs.filter { panes[$0] != nil }
    }

    func setSelected(_ ids: Set<PaneID>) {
        let live = ids.filter { panes[$0] != nil }
        let removed = selectedIDs.subtracting(live)
        let added = live.subtracting(selectedIDs)
        selectedIDs = live
        for id in removed { panes[id]?.isSelected = false }
        for id in added { panes[id]?.isSelected = true }
        // Focus follows the selection so keybinds act on the block: keep
        // focus when it is inside, else focus the topmost selected pane.
        // No selection + no focus is fine (empty canvas); otherwise keep
        // the existing focus.
        if live.isEmpty { return }
        if let f = focusedID, live.contains(f) { return }
        if let top = live.max(by: { zIndex(of: $0) < zIndex(of: $1) }) {
            focusPane(top)
        }
    }

    func toggleSelected(_ id: PaneID) {
        guard panes[id] != nil else { return }
        var next = selectedIDs
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        setSelected(next)
    }

    func clearSelection() {
        guard !selectedIDs.isEmpty else { return }
        for id in selectedIDs { panes[id]?.isSelected = false }
        selectedIDs.removeAll()
    }

    // z-order rank for deterministic block ordering (front = larger).
    func zIndex(of id: PaneID) -> Int {
        zOrder.firstIndex(of: id) ?? -1
    }

    // Group keybind on a staged selection: prompt for a name and create
    // the daemon group (clears the staging). Falls back to renaming the
    // focused pane's group when nothing is staged. Keybind path keeps
    // the 2+ minimum; single-pane named groups come from the titlebar.
    func groupStagedSelection() {
        let ids = liveSelected()
        guard ids.count >= 2 else {
            promptGroupSelection()
            return
        }
        let sorted = ids.sorted { zIndex(of: $0) < zIndex(of: $1) }
        promptName(title: "New group (\(sorted.count) panes)",
                   initial: "Group \(groupMetas.count + 1)") { [weak self] name in
            self?.createGroup(members: sorted, name: name)
            self?.clearSelection()
        }
    }

    // Close keybind with a staged selection: close every selected pane
    // when the focused pane is part of it, else just the focused pane.
    func closeSelectedOrFocused() {
        if let f = focusedID, selectedIDs.contains(f), selectedIDs.count >= 2 {
            closeSelection()
            return
        }
        if let id = focusedID { closePane(id) }
    }

    // Closing several panes kills every shell in them with no undo:
    // ask first ("Close 6 panes?" sheet), close on confirm only.
    func closeSelection() {
        let ids = liveSelected()
        guard !ids.isEmpty else { return }
        guard let window else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \(ids.count) panes?"
        alert.informativeText = "Their running shells and agents will be killed."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.clearSelection()
            for id in ids { self.closePane(id) }
        }
    }
}

// Union of explicit rects (group drag's grab-time snapshot). Same math
// as GroupGeometry.bounds (padding + title clearance) so drag deltas
// agree with the daemon's arbitration.
func groupBoundsFrom(_ rects: [PaneID: NSRect]) -> NSRect? {
    let frames = rects.values.map { NSRectOverlap.from($0) }
    guard let b = GroupGeometry.bounds(frames: frames) else { return nil }
    return NSRectOverlap.to(b)
}

extension CanvasView {
    // Shove foreigners out of a member's grown candidate bounds along the
    // motion axis. Applies moved panes live AND persists them immediately
    // (daemon resolve is idempotent on clean rects, so the stream
    // converges). Returns false when the clash is unresolvable — caller
    // must hold (not apply the candidate).
    @discardableResult
    func shoveForeignForMember(id: PaneID, memberOf: GroupID,
                               candidate: Rect, from current: NSRect,
                               axis override: (Overlap.Axis, Int)? = nil) -> Bool {
        let rects = paneRects()
        let floating = floatingPanes()
        guard GroupLayout.grownClash(moving: id, memberOf: memberOf,
                                     candidate: candidate,
                                     panes: rects, groups: groupMetas,
                                     floating: floating) else {
            return true
        }
        let dx = candidate.x - Double(current.minX)
        let dy = candidate.y - Double(current.minY)
        let (axis, sign): (Overlap.Axis, Int)
        if let override {
            (axis, sign) = override
        } else if abs(dx) >= abs(dy), dx != 0 {
            axis = .horizontal; sign = dx > 0 ? 1 : -1
        } else if dy != 0 {
            axis = .vertical; sign = dy > 0 ? 1 : -1
        } else {
            return false // no motion to shove along: hold
        }
        guard let grown = GroupLayout.grownRect(
            moving: id, memberOf: memberOf, candidate: candidate,
            panes: rects, groups: groupMetas) else { return false }
        let moves = GroupLayout.shoveAside(
            grown: grown, moving: id, memberOf: Set([memberOf]),
            panes: rects, groups: groupMetas,
            axis: axis, sign: sign,
            allowOverlap: GCTConfig.current.allowWindowOverlap,
            floating: floating, gap: Double(GCTConfig.current.windowGap))
        guard !moves.isEmpty else { return false }
        // Verify before touching anything.
        var varied = rects
        varied[id] = candidate
        for (pid, r) in moves { varied[pid] = r }
        guard !GroupLayout.grownClash(moving: id, memberOf: memberOf,
                                      candidate: candidate,
                                      panes: varied, groups: groupMetas,
                                      floating: floating) else {
            return false
        }
        for (pid, r) in moves {
            guard let pane = panes[pid] else { continue }
            let frame = NSRectOverlap.to(r)
            guard frame != pane.frame else { continue }
            pane.setRect(frame, notifySurface: false)
            hub.movePane(MovePane(id: pid, rect: r,
                            allowOverlap: GCTConfig.current.allowWindowOverlap, gap: Double(GCTConfig.current.windowGap)))
        }
        refreshGroupViews()
        refreshOcclusion()
        return true
    }

    // True when the group's grown bounds (computed over `panes`) clear
    // every foreign obstacle. Shared verify step for block moves.
    func shoveClearsBlock(grown: Rect, id: GroupID,
                          panes: [PaneID: Rect]) -> Bool {
        let foreign = GroupLayout.blockObstacles(
            moving: id, panes: panes, groups: groupMetas,
            floating: floatingPanes())
        return !foreign.contains(where: { Overlap.overlaps(grown, $0) })
    }
}
