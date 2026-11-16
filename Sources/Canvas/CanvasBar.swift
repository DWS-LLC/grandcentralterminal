// What the status bar's native cells (session, sessions, windows) read from
// the canvas, and what a click on one does. See StatusBarNative.swift.

import AppKit
import Common

extension CanvasView: StatusBarSource {
    func barSessions() -> [BarSession] {
        sessionNames.map {
            BarSession(name: $0, current: $0 == session, unread: canvases[$0]?.unread ?? 0,
                       color: HostStyle.color(for: $0))
        }
    }

    // Left to right as laid out, so a chip keeps its place while focus moves.
    func barWindows() -> [BarWindow] {
        let canvas = viewedCanvas
        let ordered = canvas.panes.values.sorted {
            ($0.frame.minX, $0.frame.minY, $0.id.description)
                < ($1.frame.minX, $1.frame.minY, $1.id.description)
        }

        return ordered.map {
            BarWindow(id: $0.id, name: $0.displayName, state: $0.programStatus?.state,
                      focused: $0.id == canvas.focusedID, notice: $0.hasNotice,
                      ended: $0.meta.exited, offline: $0.meta.offline,
                      zoomed: $0.isZoomed, floating: $0.meta.floating)
        }
    }

    func barOpen(session name: String) {
        openSession(name)
    }

    // A click is a deliberate "take me there", so the camera follows even
    // with camera-follows-focus-move off.
    func barFocus(window id: PaneID) {
        focusPane(id)
        centerOnPane(id)
    }
}
