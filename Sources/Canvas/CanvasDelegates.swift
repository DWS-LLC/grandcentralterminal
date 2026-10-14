// CanvasConnDelegate + GhosttyAppDelegate implementations for CanvasView.
// Multi-host: every callback carries the owner ("local" or [host.<name>]);
// pane/group ids are mapped to canvas space through the hub.

import AppKit
import Common

extension CanvasView: CanvasConnDelegate {
    func connWelcome(_ panes: [PaneMeta], _ groups: [GroupMeta], owner: String) {
        let mappedPanes = panes.map { hub.inboundPane($0, owner: owner) }
        let mappedGroups = groups.map { hub.inboundGroup($0, owner: owner) }
        for meta in mappedPanes {
            makePaneView(meta)
        }
        for g in mappedGroups {
            groupMetas[g.id] = g
            ensureGroupView(g.id)
        }
        refreshGroupViews()
        if owner == "local" {
            if mappedPanes.isEmpty && !firstRunHandled {
                // Empty canvas: seed one pane at the origin.
                firstRunHandled = true
                let r = newPaneRect()
                hub.createPane(CreatePane(
                    rect: Rect(x: r.minX, y: r.minY, w: r.width, h: r.height),
                    allowOverlap: GCTConfig.current.allowWindowOverlap, gap: Double(GCTConfig.current.windowGap)), owner: "local")
            } else if !mappedPanes.isEmpty {
                // Overlap allowed = the layout is the user's; never
                // rearrange it on (re)connect.
                if !GCTConfig.current.allowWindowOverlap {
                    untangleLoadedPanes()
                }
                fitAll()
            }
        } else if !mappedPanes.isEmpty {
            fitAll()
        }
    }

    func connPaneCreated(_ meta: PaneMeta, owner: String) {
        let m = hub.inboundPane(meta, owner: owner)
        makePaneView(m)
        // makePaneView focuses the new pane; camera follows only when the
        // new-window focus move fires, honoring the same flags as
        // directional moves (fit wins when both are set).
        guard GCTConfig.current.moveFocusOnNewWindow else { return }
        let cfg = GCTConfig.current
        if cfg.cameraFitsFocusMove {
            zoomToPane(m.id)
        } else if cfg.cameraFollowsFocusMove {
            centerOnPane(m.id)
        }
    }

    func connPaneMeta(_ meta: PaneMeta, owner: String) {
        let m = hub.inboundPane(meta, owner: owner)
        // Our own zoom movePane echoes back here: the zoomed pane's frame
        // is local-only until unzoom (restore persists it), so never let
        // the broadcast shrink it back to the saved rect mid-zoom.
        if zoomSavedPane == m.id { panes[m.id]?.syncMetaOnly(m); return }
        panes[m.id]?.update(meta: m)
        refreshGroupViews()
        restackFloating()
        // Daemon broadcasts relocate frames under a static camera
        // (other clients, group moves, arbitration): the frustum test
        // must follow the frames, not just the camera.
        refreshOcclusion()
    }

    func connOutput(_ id: PaneID, _ data: Data, source: OutputSource, owner: String) {
        let local = hub.localPane(remote: id, owner: owner)
        let r = programStatus.ingest(data, pane: local, source: source)
        if r.queryReply {
            // Program asked whether OSC 7501 is supported: the reply is
            // fixed bytes with nothing from any report (spec §Security).
            hub.sendInput(local, ProgramStatusStore.queryReply)
        }
        if r.changed { panes[local]?.programStatus = programStatus.summary(for: local) }
        panes[local]?.host?.feed(data)
    }

    func connPaneExit(_ id: PaneID, _ code: Int32, owner: String) {
        let local = hub.localPane(remote: id, owner: owner)
        removePane(local)
        hub.forgetPane(local)
        refreshGroupViews()
    }

    func connGroupCreated(_ meta: GroupMeta, owner: String) {
        let g = hub.inboundGroup(meta, owner: owner)
        groupMetas[g.id] = g
        ensureGroupView(g.id)
        refreshGroupViews()
    }

    func connGroupMeta(_ meta: GroupMeta, owner: String) {
        let g = hub.inboundGroup(meta, owner: owner)
        // Belt + suspenders with the daemon's delete-on-empty: an empty
        // member list here means the group is gone (stale daemon, race).
        guard !g.members.isEmpty else {
            groupViews[g.id]?.removeFromSuperview()
            groupViews.removeValue(forKey: g.id)
            groupMetas.removeValue(forKey: g.id)
            hub.forgetGroup(g.id)
            return
        }
        groupMetas[g.id] = g
        ensureGroupView(g.id)
        refreshGroupViews()
    }

    func connGroupExit(_ id: GroupID, owner: String) {
        let local = hub.localGroup(remote: id, owner: owner)
        groupViews[local]?.removeFromSuperview()
        groupViews.removeValue(forKey: local)
        groupMetas.removeValue(forKey: local)
        hub.forgetGroup(local)
    }

    // Agent/harness asked for this pane (gctd focus): focus + raise like
    // a local move, camera honoring the focus-move flags (fit wins).
    func connFocusPane(_ id: PaneID, owner: String) {
        let local = hub.localPane(remote: id, owner: owner)
        guard panes[local] != nil else { return }
        focusPane(local, raise: true)
        let cfg = GCTConfig.current
        if cfg.cameraFitsFocusMove {
            zoomToPane(local)
        } else if cfg.cameraFollowsFocusMove {
            centerOnPane(local)
        }
    }

    // Scripted camera/action (gctd camera / gctd do).
    func connCanvasCommand(_ cmd: CanvasCommand, owner: String) {
        var c = cmd
        // Remap the target pane into canvas space when present.
        if let p = cmd.pane {
            c.pane = hub.localPane(remote: p, owner: owner)
        }
        runCanvasCommand(c)
    }

    func connClosed(owner: String) {
        if owner == "local" {
            // Daemon died: try to restart it and reconnect.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                CanvasView.ensureDaemon()
                self.hub.disconnect(owner: "local")
                if self.hub.connectLocal(sockPath: CanvasPaths.sockPath, delegate: self) {
                    // Fresh welcome re-maps; drop stale local panes first
                    // so dead ids don't linger as frozen frames.
                    self.removeOwnerPanes(owner: "local")
                }
            }
        } else {
            // Remote dropped: clear its panes now, retry on reload-config
            // (no auto-reconnect loop hammering a dead host).
            removeOwnerPanes(owner: owner)
            hub.disconnect(owner: owner)
            NSLog("[gct] remote host \(owner) disconnected (reload-config to retry)")
        }
    }

    /// Remove every pane + group owned by `owner` (disconnect/reconnect).
    func removeOwnerPanes(owner: String) {
        let owned = panes.keys.filter { hub.owner(of: $0) == owner }
        for id in owned { removePane(id); hub.forgetPane(id) }
        let ownedGroups = groupMetas.keys.filter { hub.groupOwner(of: $0) == owner }
        for id in ownedGroups {
            groupViews[id]?.removeFromSuperview()
            groupViews.removeValue(forKey: id)
            groupMetas.removeValue(forKey: id)
            hub.forgetGroup(id)
        }
        hub.forgetOwner(owner)
        refreshGroupViews()
    }

    /// (Re)connect every configured remote. Called at setup and on
    /// reload-config: new hosts connect, dropped ones retry, removed ones
    /// have their panes cleared.
    func syncRemotes() {
        let wanted = Set(GCTConfig.current.remotes.map(\.name))
        // Removed hosts: clear panes, drop the conn + mappings.
        for owner in hub.owners() where owner != "local" && !wanted.contains(owner) {
            removeOwnerPanes(owner: owner)
            hub.disconnect(owner: owner)
        }
        // New / reconnected hosts.
        for h in GCTConfig.current.remotes where hub.conn(forOwner: h.name) == nil {
            if hub.connectRemote(h, delegate: self) {
                NSLog("[gct] remote host \(h.name) (\(h.host):\(h.port)) connected")
            } else {
                NSLog("[gct] remote host \(h.name) (\(h.host):\(h.port)) unreachable (reload-config to retry)")
            }
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
        hub.resizePane(ResizePane(id: host.paneID, cols: cols, rows: rows))
    }

    func surfaceClose(_ host: SurfaceHost, confirmed: Bool) {
        hub.closePane(host.paneID)
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
        hub.paneCwd(PaneCwd(id: host.paneID, cwd: pwd))
    }

    func surfaceBell(_ host: SurfaceHost) {
        NSSound.beep()
    }
}
