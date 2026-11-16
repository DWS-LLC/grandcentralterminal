// Sessions: one canvas per machine. "local" is this machine's gctd; every
// [host.<name>] is another machine's, attached to as a plain client, and
// only when you ask. Every attached session keeps its connection, panes and
// terminals alive; one is on screen, the rest are parked (hidden, renderers
// off) and still notify. Switching swaps what is shown and parks the
// camera, so each session keeps its own view.
//
//   local gctd ──conn──► SessionCanvas ─┐
//   host gctd ───conn──► SessionCanvas ─┼─► one shown, the rest parked
//   (attach / detach)                   ┘   (switchSession swaps them)
//
// Panes a session runs on other machines ("New remote pane") are that
// session's own: they sit in its layout and ride its daemon's peer links.

import AppKit
import Common

private let appTitle = "Grand Central Terminal"

extension CanvasView {
    private static let fadeOutSecs: TimeInterval = 0.08
    private static let fadeInSecs: TimeInterval = 0.12
    // Wait after the welcome before fading in. The glyphs re-render at the
    // new zoom ~0.3s on; a longer wait hides the soft-to-sharp pop but
    // makes the switch drag, so this trades a slight pop for speed.
    private static let fadeInDelaySecs: TimeInterval = 0.1

    /// This machine first, then every attached host.
    var sessionNames: [String] {
        [LocalHost] + GCTConfig.current.remotes.map(\.name).filter { canvases[$0] != nil }
    }

    /// Fade the canvas out, swap sessions underneath, fade the new one in.
    /// The camera never travels: it jumps to where that session left it.
    /// `then` runs once the new session is shown.
    func switchSession(to name: String, then: (() -> Void)? = nil) {
        guard name != session, canvases[name] != nil, !switchingSession else {
            if name == session { then?() }
            return
        }

        switchingSession = true

        fadeWorld(to: 0, seconds: Self.fadeOutSecs) { [weak self] in
            self?.swapSession(to: name)
            then?()
        }
    }

    // Park the session on screen, show `name`'s. Nothing reconnects: both
    // stay attached.
    private func swapSession(to name: String) {
        guard let target = canvases[name] else {
            switchingSession = false
            return
        }

        // A pane zoom owns the camera: one saved mid-zoom would come back
        // as a fullscreen terminal. parkViewed ends it first.
        parkViewed()
        sessionCameras[session] = camera

        session = name
        showViewed(target)
        refreshTitle()

        switchingSession = false
        sessionFadePending = true
        sessionFadeGen += 1
        restoreSessionCamera()
        endSessionFade()
    }

    /// Drop an attached host: its panes close, its connection ends, nothing
    /// redials it. On screen, it hands the view to local first.
    func detach(_ name: String) {
        guard name != LocalHost, canvases[name] != nil else { return }

        if session == name, let local = canvases[LocalHost] {
            parkViewed()
            sessionCameras[name] = nil
            session = LocalHost
            showViewed(local)
            restoreSessionCamera()
        }

        if showWhenAttached == name { showWhenAttached = nil }
        removeOwnerPanes(owner: name)
        hub.disconnect(owner: name)
        canvases.removeValue(forKey: name)
        sessionCameras.removeValue(forKey: name)
        refreshTitle()
    }

    /// "Grand Central Terminal — host · 3 attached": what is on screen, and
    /// how many sessions (local included) are live behind it.
    func refreshTitle() {
        var title = appTitle
        if session != LocalHost {
            title += " — \(session)"
        }
        if canvases.count > 1 {
            title += " · \(canvases.count) attached"
        }
        window?.title = title
        NotificationCenter.default.post(name: .gctBarChanged, object: nil)
    }

    /// The new session's welcome landed (or we gave up waiting): show it,
    /// once the glyphs have settled. Every welcome re-arms the delay.
    func endSessionFade() {
        guard sessionFadePending else { return }

        sessionFadeGen += 1
        let gen = sessionFadeGen
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeInDelaySecs) { [weak self] in
            guard let self, self.sessionFadeGen == gen else { return }

            self.sessionFadePending = false
            self.fadeWorld(to: 1, seconds: Self.fadeInSecs)
            self.refreshEmptyHint()
        }
    }

    private func fadeWorld(to alpha: CGFloat, seconds: TimeInterval,
                           done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = seconds
            worldView.animator().alphaValue = alpha
        }, completionHandler: done)
    }

    /// Cycle local -> attached host -> attached host -> local.
    func nextSession() {
        let names = sessionNames
        guard names.count > 1, let at = names.firstIndex(of: session) else { return }

        switchSession(to: names[(at + 1) % names.count])
    }

    /// A welcome landed: the camera as you left this session, else all of it.
    /// Every connection gets two welcomes (the hello in start() earns a
    /// second), so the saved camera stays put: taking it on the first would
    /// leave the second to fit over it. A dropped connection forgets it
    /// instead, see connClosed.
    func restoreSessionCamera() {
        // Mid switch the camera jumps (the fade hides it); otherwise it glides.
        let secs = sessionFadePending ? Self.cameraJumpSecs : nil
        guard let saved = sessionCameras[session] else {
            fitAll(duration: secs)
            return
        }

        animateCamera(to: saved, duration: secs)
    }

    /// The peer a pane's pty runs on, as the session daemon names it.
    /// Nil = the daemon's own (`host` is the session label or "local").
    func peerHost(of pane: PaneView) -> String? {
        let host = pane.meta.host
        return host == session || host == LocalHost ? nil : host
    }

    /// The focused pane's cwd, only if it's meaningful on `host`: a path on
    /// one machine means nothing to a pty on another.
    func focusedCwd(onPeer host: String?) -> String? {
        guard let pane = focusedID.flatMap({ panes[$0] }), peerHost(of: pane) == host else {
            return nil
        }

        return pane.meta.cwd
    }

    // MARK: Menus

    /// "New remote pane": one row per peer of THIS session's daemon.
    func remotePaneMenuItem(at world: CGPoint) -> NSMenuItem? {
        guard !sessionPeers.isEmpty else { return nil }

        let remote = NSMenuItem(title: "New remote pane", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "New remote pane")
        for peer in sessionPeers {
            let color = HostStyle.color(for: peer.name)
            let item = NSMenuItem(title: peer.name,
                                  action: #selector(newRemotePaneFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            // "host|x,y": the world point rides along like "New pane here".
            item.representedObject = peer.name + "|" + NSStringFromPoint(world)
            item.isEnabled = peer.up
            if let color {
                item.attributedTitle = NSAttributedString(
                    string: "  \(peer.name)", attributes: [.foregroundColor: color])
            }
            if !peer.up {
                item.view = RemoteRetryRow(name: peer.name, color: color) { [weak self] in
                    guard let self else { return }

                    self.hub.peerRetry(peer.name, owner: self.session)
                }
            }
            submenu.addItem(item)
        }
        remote.submenu = submenu
        return remote
    }

    // Where a session row stands: shown, attached (live or redialing),
    // mid-dial, or just a name in the config.
    private func sessionRowTitle(_ name: String) -> String {
        guard let canvas = canvases[name] else {
            return attaching.contains(name) ? "\(name) (attaching…)" : "\(name) (not attached)"
        }

        var title = name
        if name != LocalHost, hub.conn(forOwner: name) == nil {
            title += " (reconnecting…)"
        }
        if name != session, canvas.unread > 0 {
            title += "  ● \(canvas.unread)"
        }
        return title
    }

    // Where a session stands, for the pane browser's session rows.
    private func sessionNote(_ name: String) -> String {
        guard let canvas = canvases[name] else {
            return attaching.contains(name) ? "attaching…" : "select to attach"
        }

        if name != LocalHost, hub.conn(forOwner: name) == nil {
            return "reconnecting…"
        }
        guard name != session, canvas.unread > 0 else { return "" }

        return "● \(canvas.unread)"
    }

    /// Every configured session, attached or not: the pane browser's rows.
    func switcherSessions() -> [SwitcherSession] {
        ([LocalHost] + GCTConfig.current.remotes.map(\.name)).map {
            SwitcherSession(name: $0, note: sessionNote($0))
        }
    }

    /// "Session": every configured host, attached or not. Picking one
    /// attaches it if needed and shows it; attached hosts can be detached.
    func sessionMenuItem() -> NSMenuItem? {
        guard !GCTConfig.current.remotes.isEmpty else { return nil }

        let count = canvases.count
        let sessions = NSMenuItem(title: "Session: \(session) (\(count) attached)",
                                  action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Session")
        let names = [LocalHost] + GCTConfig.current.remotes.map(\.name)
        for name in names {
            let item = NSMenuItem(title: sessionRowTitle(name),
                                  action: #selector(switchSessionFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == session ? .on : .off
            item.isEnabled = !attaching.contains(name)
            submenu.addItem(item)
        }

        let detachable = names.filter { $0 != LocalHost && canvases[$0] != nil }
        if !detachable.isEmpty {
            submenu.addItem(.separator())
        }
        for name in detachable {
            let item = NSMenuItem(title: "Detach \(name)",
                                  action: #selector(detachFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            submenu.addItem(item)
        }
        sessions.submenu = submenu
        return sessions
    }

    @objc func switchSessionFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }

        openSession(name)
    }

    @objc func detachFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }

        detach(name)
    }

    /// Show a session, attaching its host first when it isn't yet.
    func openSession(_ name: String) {
        guard name != LocalHost else {
            switchSession(to: name)
            return
        }

        attach(name)
    }
}
