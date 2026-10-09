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
        // Panes always above group backgrounds.
        for view in groupViews.values { view.removeFromSuperview() }
        for (id, view) in groupViews {
            guard groupMetas[id] != nil else { continue }
            worldView.addSubview(view, positioned: .below, relativeTo: nil)
        }
        for id in zOrder {
            if let pane = panes[id] {
                pane.removeFromSuperview()
                worldView.addSubview(pane)
            }
        }
    }

    func topGroup(at worldPoint: CGPoint) -> GroupView? {
        // Frontmost = last touched; zOrder of panes approximates it.
        // Walk groups in reverse creation order (dict order is stable
        // enough for a tiebreak here; overlapping groups are an edge).
        for view in groupViews.values.reversed() {
            if view.containsWorld(worldPoint) { return view }
        }
        return nil
    }

    // MARK: Group membership mutations (daemon round-trip)

    func createGroup(members: [PaneID], name: String? = nil) {
        guard members.count >= 2 else { return }
        let color = GroupStyle.palette[groupMetas.count % GroupStyle.palette.count]
        conn?.createGroup(CreateGroup(name: name, color: color,
                                      members: members))
    }

    func ungroup(_ id: GroupID) {
        conn?.deleteGroup(id)
    }

    func renameGroup(_ id: GroupID, name: String?) {
        guard var g = groupMetas[id] else { return }
        g.name = GroupStyle.sanitizedName(name)
        groupMetas[id] = g
        refreshGroupViews()
        conn?.updateGroup(UpdateGroup(id: id, name: g.name,
                                      color: g.color, members: g.members))
    }

    func setGroupMembers(_ id: GroupID, members: [PaneID]) {
        guard var g = groupMetas[id] else { return }
        g.members = members
        groupMetas[id] = g
        refreshGroupViews()
        conn?.updateGroup(UpdateGroup(id: id, name: g.name,
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

    // Panes fully inside the finished band (titlebar included). Prompts
    // for a name, then creates (daemon assigns the color + broadcasts).
    func finishSelectionBand() {
        defer { selectionBand = nil }
        guard let band = selectionBand else { return }
        let rect = selectionRect(band)
        guard rect.width > 8, rect.height > 8 else { return }
        var picked = [PaneID]()
        for (id, pane) in panes where rect.contains(pane.frame) {
            picked.append(id)
        }
        guard picked.count >= 2 else { return }
        let ids = picked
        promptName(title: "New group (\(ids.count) panes)",
                   initial: "Group \(groupMetas.count + 1)") { [weak self] name in
            self?.createGroup(members: ids, name: name)
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
        guard GroupLayout.grownClash(moving: id, memberOf: memberOf,
                                     candidate: candidate,
                                     panes: rects, groups: groupMetas) else {
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
            allowOverlap: GCTConfig.current.allowWindowOverlap)
        guard !moves.isEmpty else { return false }
        // Verify before touching anything.
        var varied = rects
        varied[id] = candidate
        for (pid, r) in moves { varied[pid] = r }
        guard !GroupLayout.grownClash(moving: id, memberOf: memberOf,
                                      candidate: candidate,
                                      panes: varied, groups: groupMetas) else {
            return false
        }
        for (pid, r) in moves {
            guard let pane = panes[pid] else { continue }
            let frame = NSRectOverlap.to(r)
            guard frame != pane.frame else { continue }
            pane.setRect(frame, notifySurface: false)
            conn?.movePane(MovePane(id: pid, rect: r,
                            allowOverlap: GCTConfig.current.allowWindowOverlap))
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
            moving: id, panes: panes, groups: groupMetas)
        return !foreign.contains(where: { Overlap.overlaps(grown, $0) })
    }
}
