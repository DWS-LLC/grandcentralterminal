// CanvasConnDelegate + GhosttyAppDelegate implementations for CanvasView.

import AppKit
import Common

extension CanvasView: CanvasConnDelegate {
    func connWelcome(_ panes: [PaneMeta], _ groups: [GroupMeta]) {
        for meta in panes {
            makePaneView(meta)
        }
        for g in groups {
            groupMetas[g.id] = g
            ensureGroupView(g.id)
        }
        refreshGroupViews()
        if panes.isEmpty && !firstRunHandled {
            // Empty canvas: seed one pane at the origin.
            firstRunHandled = true
            let r = newPaneRect()
            conn?.createPane(CreatePane(
                rect: Rect(x: r.minX, y: r.minY, w: r.width, h: r.height),
                allowOverlap: GCTConfig.current.allowWindowOverlap))
        } else if !panes.isEmpty {
            if !GCTConfig.current.allowWindowOverlap {
                untangleLoadedPanes()
            }
            fitAll()
        }
    }

    func connPaneCreated(_ meta: PaneMeta) {
        makePaneView(meta)
        // makePaneView focuses the new pane; camera follows only when the
        // new-window focus move fires, honoring the same flags as
        // directional moves (fit wins when both are set).
        guard GCTConfig.current.moveFocusOnNewWindow else { return }
        let cfg = GCTConfig.current
        if cfg.cameraFitsFocusMove {
            zoomToPane(meta.id)
        } else if cfg.cameraFollowsFocusMove {
            centerOnPane(meta.id)
        }
    }

    func connPaneMeta(_ meta: PaneMeta) {
        panes[meta.id]?.update(meta: meta)
        refreshGroupViews()
        restackFloating()
        // Daemon broadcasts relocate frames under a static camera
        // (other clients, group moves, arbitration): the frustum test
        // must follow the frames, not just the camera.
        refreshOcclusion()
    }

    func connOutput(_ id: PaneID, _ data: Data) {
        panes[id]?.host?.feed(data)
    }

    func connPaneExit(_ id: PaneID, _ code: Int32) {
        removePane(id)
        refreshGroupViews()
    }

    func connGroupCreated(_ meta: GroupMeta) {
        groupMetas[meta.id] = meta
        ensureGroupView(meta.id)
        refreshGroupViews()
    }

    func connGroupMeta(_ meta: GroupMeta) {
        groupMetas[meta.id] = meta
        ensureGroupView(meta.id)
        refreshGroupViews()
    }

    func connGroupExit(_ id: GroupID) {
        groupMetas.removeValue(forKey: id)
        groupViews[id]?.removeFromSuperview()
        groupViews.removeValue(forKey: id)
    }

    func connClosed() {
        // Daemon died: try to restart it and reconnect.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            CanvasView.ensureDaemon()
            self.conn = CanvasConn(sockPath: CanvasPaths.sockPath)
            self.conn?.delegate = self
            self.conn?.start()
        }
    }

    // Spawn gctd if it isn't already listening.
    static func ensureDaemon() {
        let probe = connectUnixSocket(CanvasPaths.sockPath)
        if probe >= 0 {
            _ = Darwin.close(probe)  // probe only; don't leak the fd
            return
        }
        let bin = CanvasPaths.daemonPath
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            NSLog("[gct] daemon binary missing at \(bin)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        // Give it a moment to bind.
        for _ in 0..<50 {
            Thread.sleep(forTimeInterval: 0.05)
            if connectUnixSocket(CanvasPaths.sockPath) >= 0 { return }
        }
    }
}

extension CanvasView: GhosttyAppDelegate {
    func surfaceResize(_ host: SurfaceHost, _ cols: UInt16, _ rows: UInt16) {
        conn?.resizePane(ResizePane(id: host.paneID, cols: cols, rows: rows))
    }

    func surfaceClose(_ host: SurfaceHost, confirmed: Bool) {
        conn?.closePane(host.paneID)
    }

    func surfaceTitle(_ host: SurfaceHost, _ title: String) {
        if let pane = panes[host.paneID] {
            var m = pane.meta
            m.title = title
            pane.update(meta: m)
        }
    }

    func surfacePwd(_ host: SurfaceHost, _ pwd: String) {
        // The daemon tracks cwd via proc polling for local panes; OSC 7
        // from remote (ssh) panes lands here — tell the daemon so the
        // titlebar and persisted cwd stay correct.
        guard let pane = panes[host.paneID] else { return }
        var m = pane.meta
        m.cwd = pwd
        pane.update(meta: m)
        conn?.paneCwd(PaneCwd(id: host.paneID, cwd: pwd))
    }

    func surfaceBell(_ host: SurfaceHost) {
        NSSound.beep()
    }
}
