// Sessions: one canvas per machine. "local" is this machine's gctd; every
// [host.<name>] is another machine's, attached to as a plain client. Only
// one is on screen: switching swaps the whole canvas (panes, groups, ties)
// and parks the camera, so each session keeps its own view.
//
//   local gctd ──┐
//                ├─ one live CanvasConn ─► canvas      (switchSession swaps it)
//   host gctd ───┘
//
// Panes a session runs on other machines ("New remote pane") are that
// session's own: they sit in its layout and ride its daemon's peer links.

import AppKit
import Common

private let appTitle = "Grand Central Terminal"

extension CanvasView {
    private static let fadeOutSecs: TimeInterval = 0.08
    private static let fadeInSecs: TimeInterval = 0.12
    private static let fadeGiveUpSecs: TimeInterval = 1.5
    // Wait after the welcome before fading in. The glyphs re-render at the
    // new zoom ~0.3s on; a longer wait hides the soft-to-sharp pop but
    // makes the switch drag, so this trades a slight pop for speed.
    private static let fadeInDelaySecs: TimeInterval = 0.1

    /// This machine first, then every configured host.
    var sessionNames: [String] {
        [LocalHost] + GCTConfig.current.remotes.map(\.name)
    }

    /// Fade the canvas out, swap sessions underneath, fade the new one in.
    /// The camera never travels: it jumps to where that session left it.
    func switchSession(to name: String) {
        guard name != session, sessionNames.contains(name), !switchingSession else { return }

        switchingSession = true

        // A pane zoom owns the camera: one saved mid-zoom would come back
        // as a fullscreen terminal.
        if zoomSavedPane == nil {
            sessionCameras[session] = camera
        }

        let leaving = session
        fadeWorld(to: 0, seconds: Self.fadeOutSecs) { [weak self] in
            self?.swapSession(from: leaving, to: name)
        }
    }

    private func swapSession(from leaving: String, to name: String) {
        session = name
        sessionPeers = []
        remoteRetry.cancel()
        removeOwnerPanes(owner: leaving)
        hub.disconnect(owner: leaving)
        window?.title = name == LocalHost ? appTitle : "\(appTitle) — \(name)"

        switchingSession = false
        sessionFadePending = true
        sessionFadeGen += 1

        // A host that never answers must not leave the canvas invisible.
        let gen = sessionFadeGen
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeGiveUpSecs) { [weak self] in
            guard let self, self.sessionFadeGen == gen else { return }

            self.endSessionFade()
        }

        guard name == LocalHost else {
            syncRemotes()
            return
        }

        reconnectLocal(after: 0)
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
        }
    }

    private func fadeWorld(to alpha: CGFloat, seconds: TimeInterval,
                           done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = seconds
            worldView.animator().alphaValue = alpha
        }, completionHandler: done)
    }

    /// Cycle local -> host -> host -> local.
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

    /// "Session": switch the whole canvas to another machine's.
    func sessionMenuItem() -> NSMenuItem? {
        guard !GCTConfig.current.remotes.isEmpty else { return nil }

        let sessions = NSMenuItem(title: "Session: \(session)", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Session")
        for name in sessionNames {
            let item = NSMenuItem(title: name,
                                  action: #selector(switchSessionFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == session ? .on : .off
            submenu.addItem(item)
        }
        sessions.submenu = submenu
        return sessions
    }

    @objc func switchSessionFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }

        switchSession(to: name)
    }
}
