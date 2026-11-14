// A pane whose pty runs on a peer daemon. It holds the pane's slot in THIS
// session (rect, name, group, cables); bytes, keys and resizes relay over the
// peer link, and the local ring fills from the stream so dump and attach
// replay work like they do for a local pty.
//
//   keys ─► writeStdin ─► PeerLink ─► peer guest pty
//   ring ◄─ fanOut ◄───── peerOutput ◄─┘

import Foundation
import Common

final class RemotePane: Pane {
    let hostName: String

    private let routeLock = NSLock()
    private var link: PeerLink?
    private var peerID: PaneID?
    private var cols: UInt16 = 80
    private var rows: UInt16 = 24

    init(meta: PaneMeta, hostName: String, remoteID: PaneID?) {
        self.hostName = hostName
        self.peerID = remoteID
        super.init(meta: meta, command: nil)
    }

    /// The guest's id on the peer; nil until the peer has made it.
    var remoteID: PaneID? {
        routeLock.lock(); defer { routeLock.unlock() }
        return peerID
    }

    var size: (cols: UInt16, rows: UInt16) {
        routeLock.lock(); defer { routeLock.unlock() }
        return (cols, rows)
    }

    /// Point the pane at a (re)dialed link and the guest that serves it.
    func bind(link: PeerLink, remoteID: PaneID) {
        routeLock.lock(); defer { routeLock.unlock() }
        self.link = link
        self.peerID = remoteID
    }

    private func route() -> (PeerLink, PaneID)? {
        routeLock.lock(); defer { routeLock.unlock() }
        guard let link, link.isUp, let peerID else { return nil }

        return (link, peerID)
    }

    // No pty here: nothing to spawn, no reader thread. The peer link feeds
    // the server, and a link that is down simply drops input.
    override func spawn(cols: UInt16, rows: UInt16) throws {}

    override func startIO(_ onOutput: @escaping (Pane, Data) -> Void,
                          _ onEOF: @escaping (Pane) -> Void) {}

    override func writeStdin(_ data: Data) {
        guard let (link, id) = route() else { return }

        link.input(id, data)
    }

    override func resize(cols: UInt16, rows: UInt16) {
        routeLock.lock()
        self.cols = cols
        self.rows = rows
        routeLock.unlock()

        guard let (link, id) = route() else { return }

        link.resize(id, cols: cols, rows: rows)
    }

    // Closing the proxy closes the guest. A dead link can't deliver it; the
    // host reaps that guest on the next reconcile.
    override func terminate() {
        guard let (link, id) = route() else { return }

        link.close(id)
    }

    // Nothing to waitpid: let the server's reaping list drop it at once.
    override var reaped: Bool { true }
}
