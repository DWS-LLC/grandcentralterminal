// One outbound link from this daemon to a peer gctd ([host.<name>]).
//
//   canvas ─► local gctd ─► RemotePane ─► PeerLink ──tcp──► peer gctd ─► guest pty
//   canvas ◄─ local ring ◄─ peerOutput ◄──────────────────────┘
//
// The link is a plain gctd client that says who it is (Hello.owner), so the
// peer hands it guest panes and nothing of its own session. It redials with
// backoff for as long as the host stays configured, and reports up/down to
// the delegate; deciding what a drop means for panes is the delegate's job.

import Foundation
import Common

enum PeerOutput {
    case live, replay
}

enum PeerError: Error, CustomStringConvertible {
    case offline
    case timeout
    case rejected(String)

    var description: String {
        switch self {
        case .offline: return "host is offline"
        case .timeout: return "host did not answer"
        case .rejected(let why): return why
        }
    }
}

protocol PeerLinkDelegate: AnyObject {
    func peerUp(_ link: PeerLink, welcome: Welcome)
    func peerDown(_ link: PeerLink)
    func peerOutput(_ link: PeerLink, id: PaneID, data: Data, source: PeerOutput)
    func peerMeta(_ link: PeerLink, meta: PaneMeta)
    func peerExit(_ link: PeerLink, id: PaneID, code: Int32)
}

typealias PeerCreated = (Result<PaneMeta, PeerError>) -> Void

final class PeerLink: @unchecked Sendable {
    let host: PeerHost
    weak var delegate: PeerLinkDelegate?

    private let ownerID: String
    private let lock = NSLock()  // guards conn, linkUp, pending
    private var conn: Conn?
    private var linkUp = false
    private var claimed = false  // creates wait for the claim: the host reaps guests it lists as unclaimed
    private var pending = [(reqID: String, done: PeerCreated)]()

    // Run-loop control, under its own condition so a nap can be cut short.
    private let wake = NSCondition()
    private var halted = false
    private var retryRequested = false

    // Writes go through one serial queue: a stalled socket never blocks the
    // thread that asked, and keystrokes keep their order.
    private let outbox: DispatchQueue

    private static let minRetry: TimeInterval = 2
    private static let maxRetry: TimeInterval = 60
    private static let handshakeTimeout = 10
    private static let createTimeout: TimeInterval = 15

    init(host: PeerHost, ownerID: String) {
        self.host = host
        self.ownerID = ownerID
        self.outbox = DispatchQueue(label: "gctd.peer.\(host.name)")
    }

    var isUp: Bool {
        lock.lock(); defer { lock.unlock() }
        return linkUp
    }

    func start() {
        Thread(block: { [self] in run() }).start()
    }

    func stop() {
        wake.lock()
        halted = true
        wake.broadcast()
        wake.unlock()

        lock.lock()
        let c = conn
        lock.unlock()
        c?.close()
    }

    /// Cut the backoff short and dial now.
    func retryNow() {
        wake.lock()
        retryRequested = true
        wake.broadcast()
        wake.unlock()
    }

    // MARK: Requests (all non-blocking; dropped while the link is down)

    func create(_ req: CreatePane, done: @escaping PeerCreated) {
        let reqID = UUID().uuidString
        var out = req
        out.reqID = reqID
        out.host = nil

        lock.lock()
        guard linkUp, claimed else {
            lock.unlock()
            done(.failure(.offline))
            return
        }
        pending.append((reqID, done))
        lock.unlock()

        send(.createPane, out)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.createTimeout) { [weak self] in
            self?.resolve(reqID, .failure(.timeout))
        }
    }

    func attach(_ id: PaneID, cols: UInt16, rows: UInt16) {
        send(.attachPane, AttachPane(id: id, cols: cols, rows: rows))
    }

    func resize(_ id: PaneID, cols: UInt16, rows: UInt16) {
        send(.resizePane, ResizePane(id: id, cols: cols, rows: rows))
    }

    func close(_ id: PaneID) {
        send(.closePane, PaneRef(id: id))
    }

    func claim(_ ids: [PaneID]) {
        send(.claimGuests, GuestClaim(ids: ids))

        lock.lock()
        claimed = true
        lock.unlock()
    }

    func input(_ id: PaneID, _ data: Data) {
        guard let c = liveConn() else { return }

        outbox.async { _ = c.sendData(tag: .inputPane, paneID: id, data: data) }
    }

    private func send(_ tag: MsgTag, _ json: some Codable & Sendable) {
        guard let c = liveConn() else { return }

        outbox.async { _ = c.send(tag: tag, json: json) }
    }

    private func liveConn() -> Conn? {
        lock.lock(); defer { lock.unlock() }
        return linkUp ? conn : nil
    }

    // MARK: Run loop

    private var isHalted: Bool {
        wake.lock(); defer { wake.unlock() }
        return halted
    }

    private func run() {
        var delay = Self.minRetry
        var reachable = false

        while !isHalted {
            let dialed = dial()
            if dialed == nil, reachable {
                log("peer \(host.name) unreachable (retrying)")
            }
            reachable = dialed != nil

            if let (c, welcome) = dialed {
                delay = Self.minRetry
                serve(c, welcome)
            }

            nap(delay)
            delay = min(delay * 2, Self.maxRetry)
        }
    }

    private func nap(_ seconds: TimeInterval) {
        wake.lock(); defer { wake.unlock() }
        let deadline = Date().addingTimeInterval(seconds)
        while !retryRequested, !halted, Date() < deadline {
            _ = wake.wait(until: deadline)
        }
        retryRequested = false
    }

    // Connect, say hello as a peer, and wait for the welcome. Nil on any
    // failure (down, bad token, speaks too old a protocol).
    private func dial() -> (Conn, Welcome)? {
        let fd = host.proxy.isEmpty
            ? connectTCP(host: host.host, port: host.port)
            : connectSSHProxy(proxy: host.proxy, host: host.host, port: host.port)
        guard fd >= 0 else { return nil }

        let c = Conn(fd: fd)
        _ = c.send(tag: .hello, json: Hello(token: host.token.isEmpty ? nil : host.token,
                                            owner: ownerID))
        // A port that accepts but never answers must not park this thread.
        c.setReadTimeout(Self.handshakeTimeout)
        var first = c.readFrame()
        while let f = first, f.tag != .welcome, f.tag != .errorReply {
            first = c.readFrame()
        }
        c.setReadTimeout(0)

        guard let first, first.tag == .welcome, let w: Welcome = first.decode() else {
            c.close()
            return nil
        }
        guard w.version >= PeerProtoVersion else {
            log("peer \(host.name) speaks proto \(w.version), need \(PeerProtoVersion)")
            c.close()
            return nil
        }
        return (c, w)
    }

    // Up from the welcome until the socket drops.
    private func serve(_ c: Conn, _ welcome: Welcome) {
        lock.lock()
        conn = c
        linkUp = true
        lock.unlock()

        log("peer \(host.name) up")
        delegate?.peerUp(self, welcome: welcome)
        c.readLoop { [weak self] frame in self?.handle(frame) }

        lock.lock()
        conn = nil
        linkUp = false
        claimed = false
        let dropped = pending
        pending.removeAll()
        lock.unlock()

        c.close()
        for p in dropped {
            p.done(.failure(.offline))
        }
        log("peer \(host.name) down")
        delegate?.peerDown(self)
    }

    private func handle(_ frame: Frame) {
        switch frame.tag {
        case .paneCreated:
            guard let m: PaneCreated = frame.decode(), let reqID = m.reqID else { return }
            // Timed out already: nobody owns this guest, don't leave its shell running.
            if !resolve(reqID, .success(m.meta)) {
                close(m.meta.id)
            }
        case .errorReply:
            guard let e: ErrorReply = frame.decode(), let reqID = e.reqID else { return }
            resolve(reqID, .failure(.rejected(e.message)))
        case .outputPane:
            guard let id = frame.paneID else { return }
            delegate?.peerOutput(self, id: id, data: frame.data, source: .live)
        case .replayPane:
            guard let id = frame.paneID else { return }
            delegate?.peerOutput(self, id: id, data: frame.data, source: .replay)
        case .paneMeta:
            guard let m: PaneMeta = frame.decode() else { return }
            delegate?.peerMeta(self, meta: m)
        case .paneExit:
            guard let e: PaneExit = frame.decode() else { return }
            delegate?.peerExit(self, id: e.id, code: e.code)
        default:
            break
        }
    }

    // Answer a create once; later duplicates (timeout vs reply) are no-ops.
    // Off the read thread: the callback may block on UI-client writes.
    // False when nothing was waiting for it.
    @discardableResult
    private func resolve(_ reqID: String, _ result: Result<PaneMeta, PeerError>) -> Bool {
        lock.lock()
        let hit = pending.firstIndex { $0.reqID == reqID }.map { pending.remove(at: $0) }
        lock.unlock()

        guard let hit else { return false }

        DispatchQueue.global().async { hit.done(result) }
        return true
    }
}
