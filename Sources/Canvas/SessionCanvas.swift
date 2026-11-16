// SessionCanvas: everything one attached session owns on the canvas.
//
//   CanvasView.cur ──► SessionCanvas (the one every `panes`/`zOrder`/... call reads)
//   CanvasView.canvases[owner] ──► one per attached session
//
// The viewed session's views sit in the world; a parked one keeps its conn,
// panes and ghostty surfaces alive but hidden and occluded, so it still
// notifies. `CanvasView.withCanvas(owner)` points `cur` at a parked session
// for the length of one daemon callback, so the pane code never knows.

import AppKit
import Common

final class SessionCanvas {
    var panes = [PaneID: PaneView]()
    var zOrder = [PaneID]()
    var focusedID: PaneID?
    var focusTrail = FocusTrail()
    var selectedIDs = Set<PaneID>()
    var groupMetas = [GroupID: GroupMeta]()
    var groupViews = [GroupID: GroupView]()
    // The session daemon's own peer hosts: the "New remote pane" rows.
    var peers = [PeerInfo]()
    // Its daemon has told us what it holds; before that, empty means unknown.
    var welcomed = false

    /// Panes wearing the "●" that nobody has looked at yet.
    var unread: Int { panes.values.filter(\.hasNotice).count }
}
