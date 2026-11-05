// CanvasConnDelegate + GhosttyAppDelegate implementations for CanvasView.
// Multi-host: every callback carries the owner ("local" or [host.<name>]);
// pane/group ids are mapped to canvas space through the hub.

import AppKit
import Common

extension CanvasView: CanvasConnDelegate {
    func connWelcome(_ panes: [PaneMeta], _ groups: [GroupMeta], owner: String) {
        let mappedPanes = panes.map { hub.inboundPane($0, owner: owner) }
        let mappedGroups = groups.map { hub.inboundGroup($0, owner: owner) }
        hub.setLayoutPolicy(layoutPolicy(), owner: owner)
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
                askPane(CreatePane(
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
        // Panes we asked for get focus + camera. Ones spawned by gctd,
        // agents, or other clients must not steal focus or yank the view
        // (unless nothing is focused yet).
        let mine = takeOwnPaneAsk(owner: owner)
        makePaneView(m, focus: mine || focusedID == nil ? .focus : .keep)
        guard mine, GCTConfig.current.moveFocusOnNewWindow else { return }
        followFocus(m.id)
    }

    func connPaneMeta(_ meta: PaneMeta, owner: String) {
        let m = hub.inboundPane(meta, owner: owner)
        // Our own zoom movePane echoes back here: the zoomed pane's frame
        // is local-only until unzoom (restore persists it), so never let
        // the broadcast shrink it back to the saved rect mid-zoom.
        if zoomSavedPane == m.id { panes[m.id]?.syncMetaOnly(m); return }
        panes[m.id]?.update(meta: m)
        autoNameRefresh.schedule()
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
        if r.changed {
            let was = panes[local]?.programStatus?.state
            panes[local]?.programStatus = programStatus.summary(for: local)
            if source == .live { noticeStatus(local, from: was) }
        }
        if source == .live { arrange.noteOutput(local) } else { notices.noteReplay(local) }
        panes[local]?.host?.feed(data)
    }

    func connNotice(_ notice: PaneNotify, owner: String) {
        let local = hub.localPane(remote: notice.id, owner: owner)
        postNotice(local, title: notice.title, body: notice.body)
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

    func connTies(_ ties: [TieMeta], owner: String) { tiesSnapshot(ties, owner: owner) }

    func connTieMeta(_ tie: TieMeta, owner: String) { tieUpsert(tie, owner: owner) }

    func connTieExit(_ id: String, owner: String) { tieGone(id) }

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
        followFocus(local)
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
            reconnectLocal(after: Self.localReconnectDelay)
        } else {
            // Remote dropped: clear its panes now, redial on a slow timer
            // (RemoteRetry), never a tight loop hammering a dead host.
            removeOwnerPanes(owner: owner)
            hub.disconnect(owner: owner)
            NSLog("[gct] remote host \(owner) disconnected (retrying every \(Int(RemoteRetry.interval))s)")
            armRemoteRetry()
        }
    }

    private static let localReconnectDelay: TimeInterval = 0.5
    private static let localRetryInterval: TimeInterval = 5

    // Restart gctd off-main (ensureDaemon blocks while it binds), then
    // connect on main. Retries until it answers: a slow or failed restart
    // must not strand the canvas on frozen panes.
    func reconnectLocal(after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            CanvasView.ensureDaemon()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hub.disconnect(owner: "local")
                guard self.hub.connectLocal(sockPath: CanvasPaths.sockPath, delegate: self) else {
                    self.reconnectLocal(after: Self.localRetryInterval)
                    return
                }

                // Fresh welcome re-maps; drop stale local panes first
                // so dead ids don't linger as frozen frames.
                self.removeOwnerPanes(owner: "local")
            }
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
        dropTies(owner: owner)
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
        // New / reconnected hosts: dialed off-main, a dead host can't
        // freeze the UI.
        missingRemotes().forEach(redial)
        armRemoteRetry()
    }

    private func missingRemotes() -> [GCTRemoteHost] {
        GCTConfig.current.remotes.filter { hub.conn(forOwner: $0.name) == nil }
    }

    // Keeps redialing dropped hosts until every configured one is back.
    private func armRemoteRetry() {
        guard !missingRemotes().isEmpty else { return }

        remoteRetry.arm { [weak self] in
            guard let self else { return false }
            let missing = missingRemotes()
            missing.forEach(redial)
            return !missing.isEmpty
        }
    }

    // Off-main dial; adopted only if the host is still configured as it was
    // and nothing else connected it meanwhile.
    private func redial(_ h: GCTRemoteHost) {
        guard remoteRetry.begin(h.name) else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let conn = HostHub.dial(h)
            if conn == nil {
                NSLog("[gct] remote host \(h.name) (\(h.host):\(h.port)) unreachable (retrying every \(Int(RemoteRetry.interval))s)")
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.remoteRetry.end(h.name)

                let current = GCTConfig.current.remotes.contains(h)
                guard let conn, current, self.hub.conn(forOwner: h.name) == nil else {
                    conn?.close()
                    return
                }
                self.hub.adopt(conn, as: h.name, delegate: self)
                NSLog("[gct] remote host \(h.name) (\(h.host):\(h.port)) connected")
            }
        }
    }

    func retryRemote(_ name: String) {
        guard let h = GCTConfig.current.remotes.first(where: { $0.name == name }),
              hub.conn(forOwner: name) == nil else { return }
        redial(h)
    }

    // Spawn gctd if it isn't already listening.
    static func ensureDaemon() {
        DaemonInstall.stage()
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
            let fd = connectUnixSocket(CanvasPaths.sockPath)
            guard fd >= 0 else { continue }

            _ = Darwin.close(fd)  // probe only, like the one above
            return
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
            pane.reportedTitle = title
            autoNameRefresh.schedule()
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
        postNotice(host.paneID, title: nil, body: "Bell")
    }

    func surfaceNotify(_ host: SurfaceHost, title: String?, body: String) {
        postNotice(host.paneID, title: title, body: body)
    }

    // Panes report hover out of order (the one entered, then the one left),
    // so only the pane that raised the hand may drop it.
    func surfacePointer(_ host: SurfaceHost, _ shape: PointerShape) {
        switch shape {
        case .link:
            linkPane = host.paneID
            NSCursor.pointingHand.set()
        case .arrow:
            guard linkPane == host.paneID else { return }
            linkPane = nil
            NSCursor.arrow.set()
        }
    }

    func surfaceLink(_ host: SurfaceHost, _ url: String?) {
        panes[host.paneID]?.linkPreview = url
    }

    // Schemeless = file path (`~/x`, `/tmp/y`), like Ghostty's own app.
    func surfaceOpen(_ host: SurfaceHost, _ url: String) {
        if let u = URL(string: url), u.scheme != nil {
            NSWorkspace.shared.open(u)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: (url as NSString).expandingTildeInPath))
    }
}
