// CanvasConnDelegate + GhosttyAppDelegate implementations for CanvasView.
// Multi-host: every callback carries the owner ("local" or [host.<name>]);
// pane/group ids are mapped to canvas space through the hub.

import AppKit
import Common

extension CanvasView: CanvasConnDelegate {
    func connWelcome(_ panes: [PaneMeta], _ groups: [GroupMeta], owner: String) {
        withCanvas(owner) {
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
            // A parked session just fills in; camera and fade are the viewed one's.
            let viewed = owner == session
            if owner == "local" {
                if mappedPanes.isEmpty && !firstRunHandled {
                    // Empty canvas: seed one pane at the origin.
                    firstRunHandled = true
                    let r = newPaneRect()
                    askPane(CreatePane(
                        rect: Rect(x: r.minX, y: r.minY, w: r.width, h: r.height),
                        allowOverlap: GCTConfig.current.allowWindowOverlap, gap: Double(GCTConfig.current.windowGap)), owner: "local")
                } else if !mappedPanes.isEmpty && viewed {
                    // Overlap allowed = the layout is the user's; never
                    // rearrange it on (re)connect.
                    if !GCTConfig.current.allowWindowOverlap {
                        untangleLoadedPanes()
                    }
                    restoreSessionCamera()
                }
            } else if !mappedPanes.isEmpty && viewed {
                restoreSessionCamera()
            }
            if viewed {
                endSessionFade()
            }
            showAttachedSession(owner)
        }
    }

    func connPaneCreated(_ meta: PaneMeta, owner: String) {
        withCanvas(owner) {
            let m = hub.inboundPane(meta, owner: owner)
            // Panes we asked for get focus + camera. Ones spawned by gctd,
            // agents, or other clients must not steal focus or yank the view
            // (unless nothing is focused yet).
            let mine = takeOwnPaneAsk(owner: owner)
            makePaneView(m, focus: mine || focusedID == nil ? .focus : .keep)
            guard mine, GCTConfig.current.moveFocusOnNewWindow,
                  cur === viewedCanvas else { return }
            followFocus(m.id)
        }
    }

    func connPaneMeta(_ meta: PaneMeta, owner: String) {
        withCanvas(owner) {
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
    }

    func connOutput(_ id: PaneID, _ data: Data, source: OutputSource, owner: String) {
        withCanvas(owner) {
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
    }

    func connNotice(_ notice: PaneNotify, owner: String) {
        withCanvas(owner) {
            let local = hub.localPane(remote: notice.id, owner: owner)
            postNotice(local, title: notice.title, body: notice.body)
        }
    }

    func connPaneExit(_ id: PaneID, _ code: Int32, kept: Bool, owner: String) {
        withCanvas(owner) {
            let local = hub.localPane(remote: id, owner: owner)
            // keep-open: the program ended, the pane and its scrollback stay.
            if kept {
                panes[local]?.markEnded()
                return
            }
            removePane(local)
            hub.forgetPane(local)
            refreshGroupViews()
        }
    }

    func connGroupCreated(_ meta: GroupMeta, owner: String) {
        withCanvas(owner) {
            let g = hub.inboundGroup(meta, owner: owner)
            groupMetas[g.id] = g
            ensureGroupView(g.id)
            refreshGroupViews()
        }
    }

    func connGroupMeta(_ meta: GroupMeta, owner: String) {
        withCanvas(owner) {
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
    }

    func connTies(_ ties: [TieMeta], owner: String) { tiesSnapshot(ties, owner: owner) }

    func connTieMeta(_ tie: TieMeta, owner: String) { tieUpsert(tie, owner: owner) }

    func connTieExit(_ id: String, owner: String) { tieGone(id) }

    func connPeers(_ peers: [PeerInfo], owner: String) {
        canvases[owner]?.peers = peers
    }

    func connPeerState(_ peer: PeerInfo, owner: String) {
        guard let canvas = canvases[owner] else { return }

        guard let at = canvas.peers.firstIndex(where: { $0.name == peer.name }) else {
            canvas.peers.append(peer)
            return
        }
        canvas.peers[at] = peer
    }

    func connGroupExit(_ id: GroupID, owner: String) {
        withCanvas(owner) {
            let local = hub.localGroup(remote: id, owner: owner)
            groupViews[local]?.removeFromSuperview()
            groupViews.removeValue(forKey: local)
            groupMetas.removeValue(forKey: local)
            hub.forgetGroup(local)
        }
    }

    // Agent/harness asked for this pane (gctd focus): focus + raise like
    // a local move, camera honoring the focus-move flags (fit wins).
    func connFocusPane(_ id: PaneID, owner: String) {
        withCanvas(owner) {
            let local = hub.localPane(remote: id, owner: owner)
            guard panes[local] != nil else { return }
            focusPane(local, raise: true)
            guard cur === viewedCanvas else { return }
            followFocus(local)
        }
    }

    // Scripted camera/action (gctd camera / gctd do).
    func connCanvasCommand(_ cmd: CanvasCommand, owner: String) {
        var c = cmd
        // Remap the target pane into canvas space when present.
        if let p = cmd.pane {
            c.pane = hub.localPane(remote: p, owner: owner)
        }

        // Font and session are the canvas's own, whichever daemon asked.
        // Camera and actions act on the screen: only the session on it may.
        let global = c.verb == .font || c.verb == .session
        guard global || owner == session else {
            NSLog("[gct] \(owner) asked for a camera/action but is not on screen; ignored")
            return
        }

        runCanvasCommand(c)
    }

    func connClosed(owner: String) {
        // Dropped, not switched away from: the rebuilt canvas fits all again.
        sessionCameras.removeValue(forKey: owner)
        if owner == "local" {
            // Daemon died: try to restart it and reconnect.
            reconnectLocal(after: Self.localReconnectDelay)
        } else {
            // Remote dropped: clear its panes now, redial on a slow timer
            // (RemoteRetry), never a tight loop hammering a dead host.
            if showWhenAttached == owner { showWhenAttached = nil }
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
        withCanvas(owner) {
            let owned = panes.keys.filter { hub.owner(of: $0) == owner }
            for id in owned { removePane(id); hub.forgetPane(id) }
            let ownedGroups = groupMetas.keys.filter { hub.groupOwner(of: $0) == owner }
            for id in ownedGroups {
                groupViews[id]?.removeFromSuperview()
                groupViews.removeValue(forKey: id)
                groupMetas.removeValue(forKey: id)
                hub.forgetGroup(id)
            }
        }
        dropTies(owner: owner)
        hub.forgetOwner(owner)
        refreshGroupViews()
    }

    /// Point `cur` at `owner`'s session for one daemon callback, so pane code
    /// written for the viewed session also serves a parked one.
    func withCanvas(_ owner: String, _ body: () -> Void) {
        guard owner != session else {
            body()
            return
        }
        guard let target = canvases[owner] else { return }

        let was = cur
        cur = target
        defer { cur = was }

        body()
    }

    /// Attach a configured host and show it once its canvas has landed.
    /// Nothing dials a host you didn't ask for. A host that doesn't answer
    /// leaves you where you are.
    func attach(_ name: String) {
        guard canvases[name] != nil else {
            guard let h = GCTConfig.current.remotes.first(where: { $0.name == name }),
                  !attaching.contains(name) else { return }

            attaching.insert(name)
            canvases[name] = SessionCanvas()
            showWhenAttached = name
            refreshTitle()
            if !redial(h) {
                attaching.remove(name)
                abortAttach(name)
            }
            return
        }

        switchSession(to: name)
    }

    /// The attached host's first welcome built its canvas: show it, if that
    /// is what the attach was for. Deferred, so it runs outside the callback.
    func showAttachedSession(_ owner: String) {
        guard showWhenAttached == owner else { return }

        showWhenAttached = nil
        DispatchQueue.main.async { [weak self] in
            self?.switchSession(to: owner)
        }
    }

    // The dial for an explicit attach failed: back out, say so.
    private func abortAttach(_ name: String) {
        canvases.removeValue(forKey: name)
        if showWhenAttached == name { showWhenAttached = nil }
        refreshTitle()
        NSSound.beep()
    }

    /// Reload-config: an attached host that lost its config entry detaches,
    /// a dropped one is redialed. Hosts that were never attached stay alone.
    func syncRemotes() {
        let wanted = Set(GCTConfig.current.remotes.map(\.name))
        for name in canvases.keys where name != LocalHost && !wanted.contains(name) {
            detach(name)
        }

        // Dialed off-main, a dead host can't freeze the UI.
        missingRemotes().forEach { _ = redial($0) }
        armRemoteRetry()
    }

    // Attached hosts whose connection dropped.
    private func missingRemotes() -> [GCTRemoteHost] {
        GCTConfig.current.remotes.filter { canvases[$0.name] != nil && hub.conn(forOwner: $0.name) == nil }
    }

    // Keeps redialing dropped hosts until every attached one is back.
    private func armRemoteRetry() {
        guard !missingRemotes().isEmpty else { return }

        remoteRetry.arm { [weak self] in
            guard let self else { return false }
            let missing = missingRemotes()
            missing.forEach { _ = self.redial($0) }
            return !missing.isEmpty
        }
    }

    // Off-main dial; adopted only if the host is still attached and
    // configured as it was, and nothing else connected it meanwhile.
    @discardableResult
    private func redial(_ h: GCTRemoteHost) -> Bool {
        guard remoteRetry.begin(h.name) else { return false }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let conn = HostHub.dial(h)
            if conn == nil {
                NSLog("[gct] remote host \(h.name) (\(h.host):\(h.port)) unreachable (retrying every \(Int(RemoteRetry.interval))s)")
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.remoteRetry.end(h.name)

                let explicit = self.attaching.remove(h.name) != nil
                let current = self.canvases[h.name] != nil && GCTConfig.current.remotes.contains(h)
                guard let conn, current, self.hub.conn(forOwner: h.name) == nil else {
                    conn?.close()
                    if explicit, self.canvases[h.name] != nil {
                        self.abortAttach(h.name)
                    }
                    return
                }
                self.hub.adopt(conn, as: h.name, delegate: self)
                NSLog("[gct] remote host \(h.name) (\(h.host):\(h.port)) connected")
            }
        }
        return true
    }

    // Spawn gctd if it isn't already listening.
    static func ensureDaemon() {
        DaemonInstall.stage()
        let probe = connectUnixSocket(CanvasPaths.sockPath)
        if probe >= 0 {
            _ = Darwin.close(probe)  // probe only; don't leak the fd
            return
        }
        guard launchDaemon() else { return }

        // Give it a moment to bind (a first launch of the daemon app also
        // waits on Gatekeeper).
        for _ in 0..<daemonBindPolls {
            Thread.sleep(forTimeInterval: 0.05)
            let fd = connectUnixSocket(CanvasPaths.sockPath)
            guard fd >= 0 else { continue }

            _ = Darwin.close(fd)  // probe only, like the one above
            return
        }
    }

    private static let daemonBindPolls = 200

    private static func launchDaemon() -> Bool {
        if FileManager.default.fileExists(atPath: CanvasPaths.daemonAppPath) {
            return launchDaemonApp()
        }

        // Bare `swift run`: no bundle, spawn the staged binary directly.
        let bin = CanvasPaths.daemonPath
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            NSLog("[gct] daemon binary missing at \(bin)")
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        return true
    }

    // The daemon is its own app (DAEMON_APP in the Makefile): macOS ties a
    // child's LAN access to the app that spawned it, so a daemon spawned from
    // here would lose its peer links when this app quits. LaunchServices hands
    // it no environment, so GCT_* overrides (test/demo instances) ride along;
    // -n because a second instance (demo beside live) must not just reuse the
    // first.
    private static func launchDaemonApp() -> Bool {
        var args = ["-n", "-g", "-j", "--stderr", CanvasPaths.supportDir + "/daemon.log"]
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("GCT_") {
            args += ["--env", "\(key)=\(value)"]
        }
        args.append(CanvasPaths.daemonAppPath)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        do {
            try p.run()
        } catch {
            NSLog("[gct] open daemon app failed: \(error)")
            return false
        }
        p.waitUntilExit()
        return p.terminationStatus == 0
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
