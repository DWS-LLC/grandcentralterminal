// Unix-socket server: accepts UI clients, parses frames, mutates panes,
// fans pane output out to subscribers.

import Foundation
import Common

// A connected UI plus its pane subscriptions.
final class Remote: @unchecked Sendable {
    let conn: Conn
    var subs = Set<PaneID>()
    // Attaching panes: live output parks here while the replay goes out.
    var backlog = [PaneID: [Data]]()
    // Unix peers start trusted; TCP peers become trusted only after the
    // token hello. Untrusted peers get one hello chance, then dropped.
    var trusted = true
    // A peer daemon's id when this link hosts its guest panes (Hello.owner);
    // nil for UI and CLI clients.
    var peerOwner: String?
    init(conn: Conn) { self.conn = conn }
}

final class Server {
    private let state: StateStore
    private let sockPath: String
    // Optional TCP listener for remote canvases (nil = unix only).
    // token gates TCP: every TCP peer's first frame must be a hello
    // carrying it (unix peers are trusted, no token needed).
    private let tcpPort: UInt16?
    private let token: String
    private let lock = NSLock()  // guards panes + groups + remotes

    private var panes = [PaneID: Pane]()
    // Closed/exited panes whose child housekeep hasn't waitpid'd yet.
    private var reaping = [Pane]()
    // Last statuses of ended panes, so `gctd wait` after the fact still
    // answers. Oldest drops first once past the cap.
    private var exits = [PaneID: Int32]()
    private var exitOrder = [PaneID]()
    private static let exitsCap = 256
    // Group ownership: sanitized once on write; member ids pruned to
    // live panes on load and on every pane exit/close.
    private var groups = [GroupID: GroupMeta]()
    // Cable ties, by id. Each strand names a live parent -> child pair;
    // pruned on every pane exit/close, and dropped under two strands.
    private var ties = [String: TieMeta]()
    private var remotes = [Remote]()
    // Guest panes: ptys run for a peer daemon's session. Kept out of `panes`
    // so layout, groups, saves and welcomes never see them; only the owning
    // peer's link (peerRemotes) can attach, drive or list them.
    private var guests = [PaneID: Pane]()
    private var peerRemotes = [Remote]()
    private var guestLastSeen = [String: Date]()
    private static let guestTTL: TimeInterval = 7 * 24 * 3600
    // Our own links to peers, and the proxy panes riding them:
    // host name -> guest id on that host -> the pane standing in for it.
    private let peers: PeerSet
    private var proxies = [String: [PaneID: RemotePane]]()
    // Slots promised to proxies still waiting on their peer. Not in `panes`
    // yet, so a concurrent create would otherwise land on top of them.
    private var reserved = [PaneID: Rect]()
    private static let terminalReset = Data([0x1b, 0x63])  // ESC c (RIS)
    // Set by shutdown(): no more saves, no second teardown.
    private var stopping = false
    // Canvas window-gap (LayoutPolicy); floor for every placement.
    private var layoutGap: Double = 0
    private static let maxGap: Double = 256
    private static let maxTitleClearance: Double = 256

    init(state: StateStore, sockPath: String, tcpPort: UInt16? = nil,
         token: String = "", daemonID: String) {
        self.state = state
        self.sockPath = sockPath
        self.tcpPort = tcpPort
        self.token = token
        self.peers = PeerSet(ownerID: daemonID)
    }

    func run() {
        // Existing panes from a previous life: respawn their shells.
        // Groups restore with members pruned to live panes.
        let saved = state.load()
        let savedRemote = Dictionary(saved.proxies.map { ($0.pane, $0.remote) },
                                     uniquingKeysWith: { first, _ in first })
        for meta in saved.panes {
            var fresh = meta
            fresh.exited = false
            // Proxy panes keep their slot; the peer link re-attaches them.
            if fresh.host != LocalHost {
                fresh.offline = true
                let remoteID = savedRemote[fresh.id]
                let proxy = RemotePane(meta: fresh, hostName: fresh.host, remoteID: remoteID)
                panes[proxy.id] = proxy
                if let remoteID {
                    proxies[fresh.host, default: [:]][remoteID] = proxy
                }
                continue
            }
            let pane = Pane(meta: fresh, command: nil)
            do {
                try pane.spawn(cols: 80, rows: 24)
            } catch {
                log("respawn failed for \(pane.id): \(error)")
                continue
            }
            panes[pane.id] = pane
            startPaneThreads(pane)
        }
        let live = Set(panes.keys)
        for var g in saved.groups {
            g.members = g.members.filter { live.contains($0) }
            // Persisted husks (crashed before delete-on-empty landed):
            // don't resurrect them.
            guard !g.members.isEmpty else { continue }
            groups[g.id] = g
        }
        for t in saved.ties {
            guard let kept = sanitizedTieLocked(t) else { continue }
            ties[kept.id] = kept
        }

        unlink(sockPath)
        let fd = socket(AF_UNIX, sockStream, 0)
        guard fd >= 0 else { log("socket() failed: \(errno)"); return }
        // Spawned shells must not inherit daemon sockets.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        bindPath(&addr, path: sockPath)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0 else { log("bind failed: \(errno)"); return }
        guard listen(fd, 8) == 0 else { log("listen failed: \(errno)"); return }

        log("listening on \(sockPath)")

        // Housekeeping: reap children + track cwd. Needs its own run loop;
        // this thread blocks in accept() below.
        Thread(block: { [weak self] in
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.housekeep()
            }
            RunLoop.current.add(timer, forMode: .default)
            RunLoop.current.run()
        }).start()

        if let port = tcpPort {
            Thread(block: { [weak self] in self?.runTCPListener(port) }).start()
        }
        peers.start(delegate: self)

        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 {
                if errno == EINTR { continue }
                log("accept failed: \(errno)")
                return
            }
            _ = fcntl(cfd, F_SETFD, FD_CLOEXEC)
            // Unix peers are trusted; TCP peers gate on the token below.
            acceptConn(cfd, trusted: true)
        }
    }

    // Shared accept path: registers the peer, spawns its serve thread.
    // TCP callers pass trusted: false so serve() demands the token first.
    // arrangePanes applies client rects as-is; reject NaN/inf and empty ones.
    private static func sane(_ r: Rect) -> Bool {
        r.x.isFinite && r.y.isFinite && r.w.isFinite && r.h.isFinite && r.w > 0 && r.h > 0
    }

    private func acceptConn(_ cfd: Int32, trusted: Bool) {
        let remote = Remote(conn: Conn(fd: cfd))
        remote.trusted = trusted
        if trusted {
            join(remote)
        }
        Thread(block: { [weak self] in self?.serve(remote) }).start()
    }

    // Broadcasts reach only peers in remotes: TCP joins after its token.
    private func join(_ remote: Remote) {
        lock.lock()
        remotes.append(remote)
        lock.unlock()
    }

    // A peer daemon's link: never in `remotes`, so session broadcasts skip it.
    private func joinPeer(_ remote: Remote) {
        lock.lock()
        peerRemotes.append(remote)
        lock.unlock()
    }

    // Second listener for remote canvases (alongside the unix socket).
    // Runs on its own thread; every accepted fd joins the same serve().
    private func runTCPListener(_ port: UInt16) {
        let fd = listenTCP(port: port)
        guard fd >= 0 else { log("tcp listen on \(port) failed: \(errno)"); return }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        log("tcp listening on \(port)")
        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 {
                if errno == EINTR { continue }
                log("tcp accept failed: \(errno)")
                return
            }
            _ = fcntl(cfd, F_SETFD, FD_CLOEXEC)
            acceptConn(cfd, trusted: false)
        }
    }

    private func bindPath(_ addr: inout sockaddr_un, path: String) {
        withUnsafeMutablePointer(to: &addr) { p in
            let raw = UnsafeMutableRawPointer(p)
                .assumingMemoryBound(to: CChar.self)
            let off = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 2
            let dst = raw.advanced(by: off)
            let bytes = Array(path.utf8CString.prefix(Int(MemoryLayout<sockaddr_un>.size) - off))
            for (i, b) in bytes.enumerated() { dst[i] = b }
        }
    }

    // MARK: Client loop

    private func serve(_ remote: Remote) {
        defer {
            lock.lock()
            remotes.removeAll { $0 === remote }
            peerRemotes.removeAll { $0 === remote }
            if let owner = remote.peerOwner {
                guestLastSeen[owner] = Date()
            }
            remote.conn.close()
            lock.unlock()
        }

        // TCP gate: the first frame must be a token hello. Unix peers
        // skip this (trusted at accept). Wrong/missing token gets an
        // errorReply and the connection drops — no welcome, no state.
        if !remote.trusted {
            guard let first = remote.conn.readFrame(),
                  (first.tag == .hello || first.tag == .listPanes),
                  let h: Hello = first.decode(),
                  h.token == token || token.isEmpty else {
                _ = remote.conn.send(tag: .errorReply,
                                     json: ErrorReply(message: "bad token"))
                return
            }
            remote.trusted = true
            if let owner = h.owner {
                remote.peerOwner = owner
                joinPeer(remote)
            } else {
                join(remote)
            }
        }

        // Don't bail if the client is already gone (e.g. `stop` sends
        // killDaemon and exits before we write): fall through to the read
        // loop so a queued frame still lands instead of being dropped.
        _ = remote.conn.send(tag: .welcome, json: welcomePayload(for: remote))
        remote.conn.readLoop { [weak self] frame in
            self?.handle(remote, frame)
        }
    }

    private func handle(_ remote: Remote, _ frame: Frame) {
        // Belt-and-braces: serve() gates TCP up front, but a peer that
        // never authed must never mutate state even if it skips the gate.
        guard remote.trusted else {
            _ = remote.conn.send(tag: .errorReply,
                                 json: ErrorReply(message: "bad token"))
            return
        }
        switch frame.tag {
        case .hello, .listPanes:
            _ = remote.conn.send(tag: .welcome, json: welcomePayload(for: remote))

        case .killDaemon:
            shutdown()

        case .createPane:
            guard let req: CreatePane = frame.decode() else { return }
            guard remote.peerOwner == nil else {
                createGuest(remote, req)
                return
            }
            createPane(remote.conn, req)

        case .attachPane:
            guard let req: AttachPane = frame.decode() else { return }
            lock.lock()
            guard let pane = paneLocked(req.id, for: remote) else {
                lock.unlock()
                _ = remote.conn.send(tag: .errorReply,
                                     json: ErrorReply(message: "no such pane"))
                return
            }
            pane.resize(cols: req.cols, rows: req.rows)
            // Replay goes out unlocked: MiBs to a slow link would stall
            // every client. Live bytes park in the backlog meanwhile, then
            // flush under the lock so order holds:
            //   snapshot ─► replay (unlocked) ─► backlog ─► live
            remote.backlog[req.id] = []
            let snap = pane.ring.snapshot()
            lock.unlock()
            if !snap.isEmpty {
                _ = remote.conn.sendData(tag: .replayPane, paneID: req.id, data: snap)
            }

            lock.lock(); defer { lock.unlock() }
            // Gone means detached or closed mid-replay: don't subscribe.
            guard let parked = remote.backlog.removeValue(forKey: req.id) else { return }
            for data in parked {
                _ = remote.conn.sendData(tag: .outputPane, paneID: req.id, data: data)
            }
            remote.subs.insert(req.id)

        case .detachPane:
            guard let req: PaneRef = frame.decode() else { return }
            lock.lock(); defer { lock.unlock() }
            remote.subs.remove(req.id)
            remote.backlog.removeValue(forKey: req.id)

        case .inputPane:
            guard let id = frame.paneID else { return }
            lock.lock()
            let pane = paneLocked(id, for: remote)
            lock.unlock()
            pane?.writeStdin(frame.data)

        case .resizePane:
            guard let req: ResizePane = frame.decode() else { return }
            lock.lock(); defer { lock.unlock() }
            paneLocked(req.id, for: remote)?.resize(cols: req.cols, rows: req.rows)

        case .renamePane:
            guard let req: RenamePane = frame.decode() else { return }
            lock.lock()
            guard let pane = panes[req.id] else { lock.unlock(); return }
            pane.meta.name = req.name
            let meta = pane.meta
            scheduleSaveLocked()
            lock.unlock()
            broadcast(tag: .paneMeta, json: meta)

        case .movePane:
            guard let req: MovePane = frame.decode() else { return }
            lock.lock()
            guard let pane = panes[req.id] else { lock.unlock(); return }
            // Arbiter: resolve against the TRUE store before broadcast,
            // so the stream itself is overlap-free (clients apply as-is).
            // Policy comes from the client (allowOverlap flag); default
            // disallow preserves current behavior for old clients. Group
            // bounds always block non-members, regardless of the flag.
            var rect = req.rect
            let memberOf = groupOfLocked(req.id)
            let rects = paneRectsLocked()
            let metas = groupMetasLocked()
            let floating = floatingLocked()
            let obstacles = GroupLayout.moveObstacles(
                moving: req.id, memberOf: memberOf.map { Set([$0]) } ?? [],
                panes: rects, groups: metas,
                allowOverlap: req.allowOverlap, floating: floating)
            rect = Overlap.resolve(rect, obstacles: obstacles, gap: gapLocked(req.gap))
            // bounds over anything foreign — another group's bounds or a
            // loose pane. Slide along the grown bounds first (mirrors the
            // canvas static drags so the stream converges); hold the
            // current rect only when truly wedged.
            if let memberOf,
               GroupLayout.grownClash(moving: req.id, memberOf: memberOf,
                                      candidate: rect,
                                      panes: rects, groups: metas,
                                      floating: floating) {
                let slid = GroupLayout.slideGrownRect(
                    candidate: rect,
                    moving: req.id, memberOf: memberOf,
                    panes: rects, groups: metas,
                    floating: floating)
                rect = GroupLayout.grownClash(
                    moving: req.id, memberOf: memberOf, candidate: slid,
                    panes: rects, groups: metas,
                    floating: floating)
                    ? rects[req.id] ?? rect : slid
            }
            pane.meta.rect = rect
            var meta = pane.meta
            meta.rect = rect
            let targets = remotes
            scheduleSaveLocked()
            lock.unlock()
            for r in targets { _ = r.conn.send(tag: .paneMeta, json: meta) }

        case .arrangePanes:
            guard let req: ArrangePanes = frame.decode() else { return }
            lock.lock()
            var updated = [PaneMeta]()
            for m in req.moves {
                guard let pane = panes[m.id], Self.sane(m.rect) else { continue }
                pane.meta.rect = m.rect
                updated.append(pane.meta)
            }
            let targets = remotes
            scheduleSaveLocked()
            lock.unlock()
            for meta in updated {
                for r in targets { _ = r.conn.send(tag: .paneMeta, json: meta) }
            }

        case .layoutPolicy:
            guard let req: LayoutPolicy = frame.decode() else { return }
            lock.lock(); defer { lock.unlock() }
            layoutGap = min(max(req.gap, 0), Self.maxGap)
            if let c = req.titleClearance {
                GroupGeometry.titleClearance = min(max(c, 0), Self.maxTitleClearance)
            }

        case .paneCwd:
            // OSC 7 from remote panes; local panes are polled in-process.
            guard let req: PaneCwd = frame.decode() else { return }
            lock.lock(); defer { lock.unlock() }
            guard let pane = panes[req.id] else { return }
            pane.meta.cwd = req.cwd
            scheduleSaveLocked()

        case .closePane:
            guard let req: PaneRef = frame.decode() else { return }
            lock.lock()
            if panes[req.id] == nil, let guest = guestLocked(req.id, for: remote) {
                lock.unlock()
                closeGuest(guest)
                return
            }
            lock.unlock()
            closeLocalPane(req.id)

        case .setTie:
            guard let req: TieMeta = frame.decode() else { return }
            lock.lock()
            guard let tie = sanitizedTieLocked(req) else {
                lock.unlock()
                _ = remote.conn.send(tag: .errorReply, json: ErrorReply(
                    message: "a tie needs two or more cables (parent -> child)"))
                return
            }
            ties[tie.id] = tie
            scheduleSaveLocked()
            lock.unlock()
            broadcast(tag: .tieMeta, json: tie)

        case .removeTie:
            guard let req: TieRef = frame.decode() else { return }
            lock.lock()
            guard ties.removeValue(forKey: req.id) != nil else { lock.unlock(); return }
            scheduleSaveLocked()
            lock.unlock()
            broadcast(tag: .tieExit, json: TieRef(id: req.id))

        case .createGroup:
            guard let req: CreateGroup = frame.decode() else { return }
            lock.lock()
            var side = Reshuffle()
            let meta = makeGroupLocked(name: req.name, color: req.color,
                                       members: req.members, side: &side)
            scheduleSaveLocked()
            lock.unlock()
            for g in side.touched { broadcast(tag: .groupMeta, json: g) }
            for gid in side.emptied { broadcast(tag: .groupExit, json: GroupRef(id: gid)) }
            for m in side.moved { broadcast(tag: .paneMeta, json: m) }
            broadcast(tag: .groupCreated, json: GroupCreated(meta: meta, reqID: req.reqID))

        case .updateGroup:
            guard let req: UpdateGroup = frame.decode() else { return }
            lock.lock()
            guard var g = groups[req.id] else { lock.unlock(); return }
            // Membership change must not grow our bounds over a loose
            // pane (or a foreign group). Admit incrementally: current
            // members first (stability), then additions in request order,
            // keeping each only while the trial bounds stay clear.
            let live = Set(panes.keys)
            let wanted = req.members.filter { live.contains($0) }
            let rects = paneRectsLocked()
            let current = g.members.filter { live.contains($0) }
            var admitted = [PaneID]()
            var admittedSet = Set<PaneID>()
            // Panes in `wanted` are joining, not foreign: the trial grown
            // bounds must clear everything EXCEPT the full wanted set
            // (checking against admitted-so-far would refuse any two
            // panes whose padding overhangs touch — i.e. every adjacent
            // pair, the normal grouping case).
            let joining = Set(wanted)
            func clearAdding(_ id: PaneID) -> Bool {
                GroupLayout.admits(id, into: req.id, members: admitted,
                                   joining: joining, groups: groups,
                                   panes: rects)
            }
            for id in current where wanted.contains(id) {
                if clearAdding(id) { admitted.append(id); admittedSet.insert(id) }
            }
            for id in wanted where !admittedSet.contains(id) {
                if clearAdding(id) { admitted.append(id); admittedSet.insert(id) }
            }
            g.members = admitted
            g.name = GroupStyle.sanitizedName(req.name)
            g.color = GroupStyle.sanitizedColor(req.color)
            // Admitted members evicted from any other group (single
            // membership). Any group left empty — the target itself or
            // an evicted donor — is deleted, not kept as a husk.
            let fresh = Set(admitted)
            var evicted = [GroupMeta]()
            var emptied = [GroupID]()
            for (id, var other) in groups where id != req.id {
                let before = other.members.count
                other.members.removeAll { fresh.contains($0) }
                if other.members.count != before {
                    if other.members.isEmpty {
                        groups.removeValue(forKey: id)
                        emptied.append(id)
                    } else {
                        groups[id] = other
                        evicted.append(other)
                    }
                }
            }
            let updated: GroupMeta?
            if g.members.isEmpty {
                groups.removeValue(forKey: req.id)
                emptied.append(req.id)
                updated = nil
            } else {
                groups[req.id] = g
                updated = g
            }
            scheduleSaveLocked()
            lock.unlock()
            for e in evicted { broadcast(tag: .groupMeta, json: e) }
            if let updated { broadcast(tag: .groupMeta, json: updated) }
            for gid in emptied { broadcast(tag: .groupExit, json: GroupRef(id: gid)) }
        case .deleteGroup:
            guard let req: GroupRef = frame.decode() else { return }
            lock.lock()
            guard groups.removeValue(forKey: req.id) != nil else {
                lock.unlock(); return
            }
            scheduleSaveLocked()
            lock.unlock()
            broadcast(tag: .groupExit, json: req)

        case .moveGroup:
            guard let req: MoveGroup = frame.decode() else { return }
            moveGroup(req)

        case .setFloating:
            guard let req: SetFloating = frame.decode() else { return }
            lock.lock()
            guard let pane = panes[req.id] else { lock.unlock(); return }
            pane.meta.floating = req.floating
            // Un-floating re-tiles: resolve the stored rect against live
            // obstacles so the pane lands overlap-free. Floating just
            // records the flag — position never changes.
            if !req.floating && !req.allowOverlap {
                let memberOf = groupOfLocked(req.id)
                let rects = paneRectsLocked()
                let metas = groupMetasLocked()
                let floating = floatingLocked()
                let obstacles = GroupLayout.moveObstacles(
                    moving: req.id,
                    memberOf: memberOf.map { Set([$0]) } ?? [],
                    panes: rects, groups: metas,
                    allowOverlap: req.allowOverlap, floating: floating)
                var rect = Overlap.resolve(pane.meta.rect, obstacles: obstacles,
                                          gap: gapLocked(req.gap))
                if let memberOf,
                   GroupLayout.grownClash(moving: req.id, memberOf: memberOf,
                                          candidate: rect,
                                          panes: rects, groups: metas,
                                          floating: floating) {
                    let slid = GroupLayout.slideGrownRect(
                        candidate: rect, moving: req.id, memberOf: memberOf,
                        panes: rects, groups: metas,
                        floating: floating)
                    rect = GroupLayout.grownClash(
                        moving: req.id, memberOf: memberOf, candidate: slid,
                        panes: rects, groups: metas,
                        floating: floating)
                        ? rects[req.id] ?? rect : slid
                }
                pane.meta.rect = rect
            }
            let meta = pane.meta
            scheduleSaveLocked()
            lock.unlock()
            broadcast(tag: .paneMeta, json: meta)

        case .dumpPane:
            // Read-only ring snapshot. Never subscribes, never resizes:
            // agents poll this for background-task inspection.
            guard let req: DumpPane = frame.decode() else { return }
            lock.lock()
            guard let pane = paneLocked(req.id, for: remote) else {
                lock.unlock()
                _ = remote.conn.send(tag: .errorReply,
                                     json: ErrorReply(message: "no such pane"))
                return
            }
            let snap = pane.ring.snapshot()
            let dropped = pane.ring.dropped
            lock.unlock()
            let total = snap.count
            let want = req.limit <= 0 ? total : min(req.limit, total)
            let truncated = want < total
            let cut = want == total ? snap : snap.subdata(in: (total - want)..<total)
            let tail = Self.trimUTF8(cut)
            let text = String(data: tail, encoding: .utf8)
            let reply: PaneDump
            if let text {
                reply = PaneDump(id: req.id, bytes: tail.count,
                                 truncated: truncated, dropped: dropped,
                                 data: text, base64: false)
            } else {
                reply = PaneDump(id: req.id, bytes: tail.count,
                                 truncated: truncated, dropped: dropped,
                                 data: tail.base64EncodedString(), base64: true)
            }
            _ = remote.conn.send(tag: .paneDump, json: reply)

        case .waitPane:
            // Already ended: answer from the table. Live: say nothing, the
            // client is subscribed and gets the paneExit broadcast.
            guard let req: PaneRef = frame.decode() else { return }
            lock.lock()
            let ended = exits[req.id]
            let live = paneLocked(req.id, for: remote) != nil
            lock.unlock()
            if let ended {
                _ = remote.conn.send(tag: .paneExit, json: PaneExit(id: req.id, code: ended))
                return
            }
            guard !live else { return }

            _ = remote.conn.send(tag: .errorReply, json: ErrorReply(message: "no such pane"))

        case .focusPane:
            // Agent asks the canvas to focus a pane (raise + center).
            // Daemon validates + broadcasts; the canvas honors it like a
            // local focus move (honoring its camera-follows/fits flags).
            guard let req: PaneRef = frame.decode() else { return }
            lock.lock()
            guard panes[req.id] != nil else {
                lock.unlock()
                _ = remote.conn.send(tag: .errorReply,
                                     json: ErrorReply(message: "no such pane"))
                return
            }
            lock.unlock()
            broadcast(tag: .paneFocus, json: req)

        case .notifyPane:
            // Harness hook asks for a desktop notification: validate the
            // pane, then let the canvas post it (it owns notifications).
            guard let req: PaneNotify = frame.decode() else { return }
            lock.lock()
            let known = panes[req.id] != nil
            lock.unlock()
            guard known else {
                _ = remote.conn.send(tag: .errorReply,
                                     json: ErrorReply(message: "no such pane"))
                return
            }
            broadcast(tag: .paneNotice, json: req)

        case .claimGuests:
            guard let owner = remote.peerOwner, let req: GuestClaim = frame.decode() else { return }
            reapUnclaimed(owner: owner, keeping: Set(req.ids))

        case .peerRetry:
            guard let req: PeerRef = frame.decode() else { return }
            peers.link(for: req.name)?.retryNow()

        case .canvasCommand:
            // Scripted camera/action: validate the target pane, then relay
            // verbatim. The canvas owns the semantics.
            guard let req: CanvasCommand = frame.decode() else { return }
            lock.lock()
            let known = req.pane.map { panes[$0] != nil } ?? true
            lock.unlock()
            guard known else {
                _ = remote.conn.send(tag: .errorReply,
                                     json: ErrorReply(message: "no such pane"))
                return
            }
            broadcast(tag: .canvasRelay, json: req)

        default:
            break
        }
    }

    // Ring cuts (limit=, eviction) split codepoints at either end, which
    // fails strict decoding. Drop the partial sequences.
    // e.g. [A9 E2 94 80 E2 94] -> [E2 94 80]
    private static func trimUTF8(_ d: Data) -> Data {
        var lo = d.startIndex
        var hi = d.endIndex

        // Leading continuation bytes (10xxxxxx) belong to a cut codepoint.
        while lo < hi, lo - d.startIndex < maxUTF8Len - 1, d[lo] & 0xC0 == 0x80 {
            lo += 1
        }

        // Trailing: find the last lead byte; drop it if its sequence is short.
        var i = hi
        while i > lo, hi - i < maxUTF8Len {
            i -= 1
            if d[i] & 0xC0 != 0x80 {
                break
            }
        }
        if i < hi {
            let b = d[i]
            let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            if hi - i < need {
                hi = i
            }
        }
        return d.subdata(in: lo..<hi)
    }
    private static let maxUTF8Len = 4

    private func welcomePayload(for remote: Remote) -> Welcome {
        lock.lock(); defer { lock.unlock() }
        let owner = remote.peerOwner
        let visible = guests.values
            .filter { owner == nil || $0.meta.guestOf == owner }
            .sorted { $0.id.uuid.uuidString < $1.id.uuid.uuidString }
            .map(\.meta)
        // A peer link serves guests only; the session is none of its business.
        guard owner == nil else {
            return Welcome(panes: [], guests: visible)
        }

        return Welcome(panes: panes.values
            .sorted { $0.id.uuid.uuidString < $1.id.uuid.uuidString }
            .map(\.meta), groups: Array(groups.values),
            ties: ties.values.sorted { $0.id < $1.id },
            guests: visible, peers: peers.infos())
    }

    // MARK: Groups (all require `lock`)

    private func groupMetasLocked() -> [GroupID: GroupMeta] { groups }

    private func paneRectsLocked() -> [PaneID: Rect] {
        var out = [PaneID: Rect]()
        for (id, p) in panes { out[id] = p.meta.rect }
        return out
    }

    private func groupOfLocked(_ id: PaneID) -> GroupID? {
        groups.first { $0.value.members.contains(id) }?.key
    }

    private func floatingLocked() -> Set<PaneID> {
        Set(panes.values.lazy.filter(\.meta.floating).map(\.id))
    }

    private func snapshotLocked() -> SavedState {
        // An ended keep-open pane has no program to respawn.
        SavedState(panes: panes.values.filter { $0.keptSince == nil }.map(\.meta),
                   groups: Array(groups.values), ties: Array(ties.values),
                   proxies: panes.values.compactMap { pane in
                       guard let proxy = pane as? RemotePane, let remote = proxy.remoteID else { return nil }
                       return SavedProxy(pane: proxy.id, remote: remote)
                   })
    }

    // makeGroupLocked's fallout, broadcast once the lock drops.
    private struct Reshuffle {
        var touched = [GroupMeta]()
        var emptied = [GroupID]()
        var moved = [PaneMeta]()
    }

    // Create + sanitize: unknown ids dropped, members evicted from other
    // groups (single membership), color validated, empty name cleared.
    private func makeGroupLocked(name: String?, color: String?,
                                 members: [PaneID],
                                 side: inout Reshuffle) -> GroupMeta {
        let live = Set(panes.keys)
        let wanted = members.filter { live.contains($0) }
        // Every live pane is admitted; blockers are shoved out of the new
        // border below (grouping never fails for lack of room).
        let gid = GroupID()
        let admitted = wanted
        let fresh = Set(admitted)
        for (id, var other) in groups {
            let before = other.members.count
            other.members.removeAll { fresh.contains($0) }
            if other.members.count != before {
                if other.members.isEmpty {
                    groups.removeValue(forKey: id)
                    side.emptied.append(id)
                } else {
                    groups[id] = other
                    side.touched.append(other)
                }
            }
        }
        let g = GroupMeta(id: gid,
                          name: GroupStyle.sanitizedName(name),
                          color: GroupStyle.sanitizedColor(color),
                          members: admitted)
        groups[g.id] = g

        // Donors already lost the joiners above, so their shrunken bounds
        // are what gets shoved. Moves broadcast before groupCreated.
        let moves = GroupLayout.makeRoom(
            for: gid, panes: paneRectsLocked(), groups: groups,
            floating: floatingLocked(), gap: layoutGap)
        for (pid, r) in moves {
            guard let pane = panes[pid] else { continue }
            pane.meta.rect = r
            side.moved.append(pane.meta)
        }
        return g
    }

    private struct Pruned {
        var touched = [GroupMeta]()
        var emptied = [GroupID]()
        var ties = [TieMeta]()       // lost strands, still tied
        var tiesGone = [String]()    // under two strands left
    }

    // Drop a dead pane from every group and tie. Groups left with no live
    // members are deleted (empty groups don't linger in menus); ties left
    // under two strands likewise. Returns survivors for the meta
    // broadcasts, dead ids for the exit ones.
    @discardableResult
    private func prunePaneLocked(_ id: PaneID) -> Pruned {
        var out = Pruned()
        var touched = [GroupMeta]()
        var emptied = [GroupID]()
        for (gid, var g) in groups where g.members.contains(id) {
            g.members.removeAll { $0 == id }
            if g.members.isEmpty {
                groups.removeValue(forKey: gid)
                emptied.append(gid)
            } else {
                groups[gid] = g
                touched.append(g)
            }
        }
        out.touched = touched
        out.emptied = emptied

        for (tid, t) in ties {
            let live = t.strands.filter { $0.parent != id && $0.child != id }
            guard live.count != t.strands.count else { continue }

            if live.count < Self.minStrands {
                ties.removeValue(forKey: tid)
                out.tiesGone.append(tid)
                continue
            }
            var kept = t
            kept.strands = live
            ties[tid] = kept
            out.ties.append(kept)
        }
        return out
    }

    // MARK: Ties (all require `lock`)

    private static let minStrands = 2

    // Only real cables count: a strand is a live pane and the child it
    // spawned. Under two strands there is nothing to tie.
    private func sanitizedTieLocked(_ t: TieMeta) -> TieMeta? {
        var seen = Set<PaneID>()
        let strands = t.strands.filter { st in
            guard let child = panes[st.child], child.meta.parent == st.parent,
                  panes[st.parent] != nil, seen.insert(st.child).inserted else { return false }
            return st.delta.isFinite
        }
        guard strands.count >= Self.minStrands, t.s.isFinite else { return nil }

        var out = t
        out.strands = strands
        out.s = min(max(t.s, 0), 1)
        return out
    }

    // Rigid group move: shift every member by the same delta; the block
    // SLIDES along foreign collisions (static world — shoving only ever
    // happens canvas-side under allow-mouse-drag-to-push, persisted per
    // pane before the moveGroup lands, so this resolve is idempotent).
    // Members broadcast individually; clients apply as-is.
    private func moveGroup(_ req: MoveGroup) {
        lock.lock()
        guard let g = groups[req.id] else { lock.unlock(); return }
        let members = g.members.filter { panes[$0] != nil }
        guard !members.isEmpty else { lock.unlock(); return }
        let rects = paneRectsLocked()
        let metas = groupMetasLocked()
        let frames = members.compactMap { rects[$0] }
        guard let b = GroupGeometry.bounds(frames: frames) else {
            lock.unlock(); return
        }
        let obstacles = GroupLayout.blockObstacles(
            moving: req.id, panes: rects, groups: metas,
            floating: floatingLocked())
        let target = Rect(x: b.x + req.dx, y: b.y + req.dy, w: b.w, h: b.h)
        let clean = Overlap.resolve(target, obstacles: obstacles, gap: gapLocked(req.gap))
        let dx = clean.x - b.x, dy = clean.y - b.y
        var updated = [PaneMeta]()
        for id in members {
            guard let pane = panes[id] else { continue }
            var r = pane.meta.rect
            r.x += dx; r.y += dy
            pane.meta.rect = r
            updated.append(pane.meta)
        }
        scheduleSaveLocked()
        let targetsRemotes = remotes
        lock.unlock()
        for m in updated {
            for r in targetsRemotes { _ = r.conn.send(tag: .paneMeta, json: m) }
        }
    }

    private func createPane(_ requester: Conn, _ req: CreatePane) {
        // New panes are groupless unless joinGroup asks for admission
        // (directional split from a grouped pane). Joiners land FLUSH at
        // the requested rect — only foreign group bounds deflect
        // placement; loose panes in the way are shoved aside along the
        // split axis at admit time (cascade included). Foreign-group
        // clash still refuses the join (groupless pane, no error).
        lock.lock()
        let rects = paneRectsLocked().merging(reserved) { live, _ in live }
        let metas = groupMetasLocked()
        let floating = floatingLocked()
        let id = PaneID()
        let rect: Rect
        let gap = gapLocked(req.gap)
        if req.joinGroup != nil {
            var obstacles = [Rect]()
            for (gid, b) in GroupLayout.bounds(groups: metas, panes: rects)
                where gid != req.joinGroup {
                obstacles.append(b)
            }
            rect = obstacles.isEmpty ? req.rect
                : Overlap.resolve(req.rect, obstacles: obstacles, gap: gap)
        } else {
            let obstacles = GroupLayout.creationObstacles(
                paneRects: rects,
                groups: metas,
                allowOverlap: req.allowOverlap,
                floating: floating)
            rect = obstacles.isEmpty ? req.rect
                : Overlap.resolve(req.rect, obstacles: obstacles, gap: gap)
        }
        if req.host != nil {
            reserved[id] = rect
        }
        lock.unlock()
        let cwd = req.cwd ?? NSHomeDirectory()
        var meta = PaneMeta(id: id, rect: rect, name: req.name,
                            cwd: cwd, host: LocalHost, title: nil, exited: false)
        meta.parent = req.parent
        if let hostName = req.host {
            meta.host = hostName
            createProxy(requester, req, meta: meta)
            return
        }
        let pane = Pane(meta: meta, command: req.command)
        pane.keepOpen = req.keepOpen
        do {
            try pane.spawn(cols: 80, rows: 24)
        } catch {
            log("spawn failed: \(error)")
            _ = requester.send(tag: .errorReply,
                               json: ErrorReply(message: "spawn failed: \(error)", reqID: req.reqID))
            return
        }
        admit(pane, at: rect, req)
    }

    // Puts a ready pane into the layout: joins its group (shoving loose
    // panes aside), saves, and tells every client. Local ptys come here
    // straight from spawn, proxies once their peer has made the guest.
    private func admit(_ pane: Pane, at rect: Rect, _ req: CreatePane) {
        lock.lock()
        panes[pane.id] = pane
        reserved.removeValue(forKey: pane.id)
        // joinGroup: admit into the parent's group. Loose panes in the
        // grown path get SHOVED aside along the split axis first (same
        // axis/sign as keyboard grow); foreign groups never shove —
        // their clash still refuses the join (groupless pane, no error).
        // Every moved pane broadcasts its new frame.
        var joined: GroupMeta?
        var shoved = [PaneID: Rect]()
        if let join = req.joinGroup, var g = groups[join],
           !g.members.contains(pane.id) {
            var trialGroups = groups
            var trial = g
            trial.members.append(pane.id)
            trialGroups[join] = trial
            var withNew = paneRectsLocked()
            withNew[pane.id] = rect
            if let grown = GroupLayout.bounds(groups: trialGroups, panes: withNew)[join] {
                if !admitClearLocked(group: join, grown: grown, newMember: pane.id,
                                     panes: withNew),
                   let axis = joinAxis(req.joinDirection) {
                    // Shove LOOSE panes only: foreign groups are not
                    // shoveable (their bounds clash = refusal). Filter
                    // the shove result to ungrouped panes.
                    let moves = GroupLayout.shoveAside(
                        grown: grown, moving: pane.id, memberOf: Set([join]),
                        panes: withNew, groups: groups,
                        axis: axis.0, sign: axis.1,
                        // Join-shove always behaves disallowed-style:
                        // the grown block is exclusive, allowOverlap
                        // must not exempt loose panes from the push.
                        allowOverlap: false,
                        floating: floatingLocked(), gap: gapLocked(req.gap))
                    let grouped = Set(groups.values.flatMap(\.members))
                    for (pid, r) in moves where !grouped.contains(pid) {
                        withNew[pid] = r
                        shoved[pid] = r
                    }
                }
                if admitClearLocked(group: join, grown: GroupLayout.bounds(
                    groups: trialGroups, panes: withNew)[join] ?? grown,
                    newMember: pane.id, panes: withNew) {
                    g.members.append(pane.id)
                    groups[join] = g
                    joined = g
                } else {
                    shoved.removeAll()
                }
            }
        }
        for (pid, r) in shoved {
            panes[pid]?.meta.rect = r
        }
        var movedMetas = [PaneMeta]()
        for pid in shoved.keys {
            if let m = panes[pid]?.meta { movedMetas.append(m) }
        }
        scheduleSaveLocked()
        let targets = remotes
        lock.unlock()
        startPaneThreads(pane)

        broadcast(tag: .paneCreated, json: PaneCreated(meta: pane.meta, reqID: req.reqID))
        for m in movedMetas {
            broadcast(tag: .paneMeta, json: m)
        }
        if let joined {
            for r in targets { _ = r.conn.send(tag: .groupMeta, json: joined) }
        }
    }

    // Split direction -> shove axis/sign (same convention as keyboard
    // grow: new pane on the left pushes blockers left, etc.).
    private func joinAxis(_ raw: String?) -> (Overlap.Axis, Int)? {
        switch raw?.lowercased() {
        case "right": return (.horizontal, 1)
        case "left": return (.horizontal, -1)
        case "above": return (.vertical, 1)
        case "below": return (.vertical, -1)
        default: return nil
        }
    }

    // Requested gap, floored by the canvas policy: CLI requests carry 0.
    private func gapLocked(_ asked: Double) -> Double {
        max(asked, layoutGap)
    }

    // Shared grown-bounds admission: grown must clear foreign group
    // bounds and every non-member pane frame. Caller holds `lock`.
    private func admitClearLocked(group: GroupID, grown: Rect, newMember: PaneID,
                                  panes: [PaneID: Rect]) -> Bool {
        for (gid, b) in GroupLayout.bounds(groups: groups, panes: panes)
            where gid != group {
            if Overlap.overlaps(grown, b) { return false }
        }
        let inside = Set((groups[group]?.members ?? []) + [newMember])
        for (pid, r) in panes where !inside.contains(pid) {
            if Overlap.overlaps(grown, r) { return false }
        }
        return true
    }

    private func startPaneThreads(_ pane: Pane) {
        pane.startIO({ [weak self] pane, data in
            self?.fanOut(pane: pane, data: data)
        }, { [weak self] pane in
            self?.paneDied(pane, code: pane.awaitExit())
        })
    }

    private func fanOut(pane: Pane, data: Data) {
        // Ring append and target pick share the lock with attach's
        // snapshot: each chunk is either replayed or sent live, never both.
        lock.lock()
        pane.ring.append(data)
        var targets = [Remote]()
        // Guest bytes go to the owning peer's link, session bytes to UI clients.
        let audience = pane.meta.guestOf == nil ? remotes : peerRemotes
        for r in audience {
            if r.subs.contains(pane.id) {
                targets.append(r)
            } else if r.backlog[pane.id] != nil {
                r.backlog[pane.id]?.append(data)
            }
        }
        lock.unlock()
        // Blocking socket writes OUTSIDE the server lock: a full client
        // buffer stalls only this pane's reader, never control traffic.
        // A failed send hangs the client up (Conn); it reconnects + replays.
        for r in targets {
            _ = r.conn.sendData(tag: .outputPane, paneID: pane.id, data: data)
        }
    }

    // Drop a pane from the layout, hang it up and tell every client. One
    // that already ended (keep-open) hands late waiters its real status.
    private func closeLocalPane(_ id: PaneID) {
        lock.lock()
        guard let pane = panes.removeValue(forKey: id) else { lock.unlock(); return }
        let status = pane.keptSince == nil ? ExitUnknown : pane.exitCode ?? ExitUnknown
        forgetProxyLocked(pane)
        reaping.append(pane)
        for r in remotes {
            r.subs.remove(id)
            r.backlog.removeValue(forKey: id)
        }
        let pruned = prunePaneLocked(id)
        scheduleSaveLocked()
        lock.unlock()
        // The reader thread unblocks with EIO once the shell dies; its
        // paneDied becomes a no-op (untracked), so broadcast here.
        pane.terminate()
        announceExit(id, status)
        for g in pruned.touched { broadcast(tag: .groupMeta, json: g) }
        for gid in pruned.emptied { broadcast(tag: .groupExit, json: GroupRef(id: gid)) }
        broadcastTies(pruned)
    }

    // Called from the pane's reader thread (EOF/EIO) and from housekeep.
    // The reader thread owns closing the master fd; close() on macOS does
    // not unblock a blocked read, so we must not close here.
    private func paneDied(_ pane: Pane, code: Int32? = nil) {
        let status = code ?? pane.exitCode ?? ExitUnknown
        guard pane.meta.guestOf == nil else {
            guestDied(pane, status)
            return
        }

        // Check and remove in one section: reader EOF and housekeep both
        // land here, and only the first may broadcast.
        lock.lock()
        pane.markExited()
        if pane.keepOpen {
            // Stays in the layout (and in groups and ties) with its
            // scrollback; EOF and housekeep both land here, first one wins.
            let first = panes[pane.id] != nil && pane.keptSince == nil
            if first {
                pane.keptSince = Date()
                pane.meta.exited = true
                scheduleSaveLocked()
            }
            lock.unlock()
            if first { announceExit(pane.id, status, kept: true) }
            return
        }
        guard panes.removeValue(forKey: pane.id) != nil else {
            lock.unlock()
            return
        }
        forgetProxyLocked(pane)
        reaping.append(pane)
        // Late reader output must not resurrect the id client-side.
        for r in remotes {
            r.subs.remove(pane.id)
            r.backlog.removeValue(forKey: pane.id)
        }
        let pruned = prunePaneLocked(pane.id)
        scheduleSaveLocked()
        lock.unlock()

        announceExit(pane.id, status)
        for g in pruned.touched { broadcast(tag: .groupMeta, json: g) }
        for gid in pruned.emptied { broadcast(tag: .groupExit, json: GroupRef(id: gid)) }
        broadcastTies(pruned)
    }

    private func broadcastTies(_ pruned: Pruned) {
        for t in pruned.ties { broadcast(tag: .tieMeta, json: t) }
        for id in pruned.tiesGone { broadcast(tag: .tieExit, json: TieRef(id: id)) }
    }

    // Remember the status for late waiters, then tell every client.
    private func announceExit(_ id: PaneID, _ code: Int32, kept: Bool = false) {
        lock.lock()
        if exits.updateValue(code, forKey: id) == nil { exitOrder.append(id) }
        if exitOrder.count > Self.exitsCap { exits.removeValue(forKey: exitOrder.removeFirst()) }
        lock.unlock()
        broadcast(tag: .paneExit, json: PaneExit(id: id, code: code, kept: kept))
    }

    // Blocking writes outside the lock: a slow peer stalls only us.
    private func broadcast(tag: MsgTag, json: some Codable & Sendable) {
        lock.lock()
        let targets = remotes
        lock.unlock()
        for r in targets { _ = r.conn.send(tag: tag, json: json) }
    }

    private func scheduleSaveLocked() {
        guard !stopping else {
            return
        }

        state.scheduleSave(snapshotLocked())
    }

    private func housekeep() {
        var dirty = false
        var changedMetas = [PaneMeta]()
        lock.lock()
        for pane in panes.values {
            if pane.pollExit() != nil {
                dirty = true
                Task { [weak self] in self?.paneDied(pane) }
            } else {
                var changed = false
                if let cwd = pane.pollCWD() {
                    pane.meta.cwd = cwd
                    changed = true
                }
                if pane.pollContext() { changed = true }

                if changed {
                    dirty = true
                    changedMetas.append(pane.meta)
                }
            }
        }
        var guestUpdates = [PaneMeta]()
        for pane in guests.values {
            guard pane.pollExit() == nil else {
                Task { [weak self] in self?.paneDied(pane) }
                continue
            }

            var changed = false
            if let cwd = pane.pollCWD() {
                pane.meta.cwd = cwd
                changed = true
            }
            if pane.pollContext() { changed = true }
            if changed { guestUpdates.append(pane.meta) }
        }
        let expired = expiredGuestsLocked()
        // Untracked panes still need waitpid, or they linger as zombies.
        reaping.removeAll { $0.reaped || $0.pollExit() != nil }

        if dirty {
            scheduleSaveLocked()
        }
        let targets = remotes
        lock.unlock()

        for meta in changedMetas {
            for r in targets { _ = r.conn.send(tag: .paneMeta, json: meta) }
        }
        for meta in guestUpdates {
            sendToPeers(owner: meta.guestOf, tag: .paneMeta, json: meta)
        }
        for guest in expired {
            log("guest \(guest.id) of \(guest.meta.guestOf ?? "?") expired")
            closeGuest(guest)
        }
        peers.pollConfig()
        sweepKept()
    }

    // Ended keep-open panes older than keep-open-ttl get closed. The
    // config is re-read once a minute, not every tick.
    private static let keepSweepSecs: TimeInterval = 60
    private var lastKeepSweep = Date.distantPast

    private func sweepKept() {
        let now = Date()
        lock.lock()
        guard now.timeIntervalSince(lastKeepSweep) >= Self.keepSweepSecs else {
            lock.unlock()
            return
        }
        lastKeepSweep = now
        let kept = panes.values.filter { $0.keptSince != nil }
        lock.unlock()
        guard !kept.isEmpty else { return }

        // 0 = never expires.
        let ttl = PeerConfig.keepOpenTTL()
        guard ttl > 0 else { return }

        for pane in kept {
            guard let since = pane.keptSince, now.timeIntervalSince(since) > ttl else { continue }

            log("kept pane \(pane.id) expired")
            closeLocalPane(pane.id)
        }
    }

    func shutdown() {
        lock.lock()
        // Serve threads keep running through the hangup grace; without
        // this a save there would persist the emptied pane list.
        guard !stopping else {
            lock.unlock()
            return
        }

        stopping = true
        let all = Array(panes.values) + Array(guests.values)
        panes.removeAll()
        guests.removeAll()
        lock.unlock()
        state.saveNow()
        Pane.terminateAll(all)
        exit(0)
    }

    // MARK: Guests (this daemon hosts a pty for a peer's session)

    // Session panes for UI clients; a peer link sees only its own guests.
    private func paneLocked(_ id: PaneID, for remote: Remote) -> Pane? {
        guard let owner = remote.peerOwner else { return panes[id] }
        guard let guest = guests[id], guest.meta.guestOf == owner else { return nil }

        return guest
    }

    // closePane also lets a UI client reap any guest (an orphan's last resort).
    private func guestLocked(_ id: PaneID, for remote: Remote) -> Pane? {
        guard let guest = guests[id] else { return nil }
        guard let owner = remote.peerOwner else { return guest }

        return guest.meta.guestOf == owner ? guest : nil
    }

    private func createGuest(_ requester: Remote, _ req: CreatePane) {
        guard let owner = requester.peerOwner else { return }

        // The peer's cwd may not exist here (a local path from its canvas).
        var isDir: ObjCBool = false
        let asked = req.cwd.flatMap {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue ? $0 : nil
        }
        var meta = PaneMeta(id: PaneID(), rect: req.rect, name: req.name,
                            cwd: asked ?? NSHomeDirectory(), host: LocalHost,
                            title: nil, exited: false)
        meta.guestOf = owner
        let pane = Pane(meta: meta, command: req.command)
        do {
            try pane.spawn(cols: 80, rows: 24)
        } catch {
            log("guest spawn failed: \(error)")
            _ = requester.conn.send(tag: .errorReply, json: ErrorReply(
                message: "spawn failed: \(error)", reqID: req.reqID))
            return
        }

        lock.lock()
        guests[pane.id] = pane
        lock.unlock()
        startPaneThreads(pane)
        _ = requester.conn.send(tag: .paneCreated,
                                json: PaneCreated(meta: pane.meta, reqID: req.reqID))
    }

    // False when it was already retired (close and exit race).
    private func retireGuestLocked(_ pane: Pane) -> Bool {
        guard guests.removeValue(forKey: pane.id) != nil else { return false }

        reaping.append(pane)
        for r in peerRemotes {
            r.subs.remove(pane.id)
            r.backlog.removeValue(forKey: pane.id)
        }
        return true
    }

    private func closeGuest(_ pane: Pane) {
        lock.lock()
        let retired = retireGuestLocked(pane)
        lock.unlock()
        guard retired else { return }

        pane.terminate()
        sendToPeers(owner: pane.meta.guestOf, tag: .paneExit,
                    json: PaneExit(id: pane.id, code: ExitUnknown))
    }

    private func guestDied(_ pane: Pane, _ code: Int32) {
        lock.lock()
        pane.markExited()
        let retired = retireGuestLocked(pane)
        lock.unlock()
        guard retired else { return }

        sendToPeers(owner: pane.meta.guestOf, tag: .paneExit,
                    json: PaneExit(id: pane.id, code: code))
    }

    // The owner's claim is its full list of live proxies: any other guest of
    // that owner lost its proxy (crash before a save, close while the link
    // was down) and would otherwise run forever.
    private func reapUnclaimed(owner: String, keeping: Set<PaneID>) {
        lock.lock()
        let stale = guests.values.filter {
            $0.meta.guestOf == owner && !keeping.contains($0.id)
        }
        lock.unlock()

        for guest in stale {
            log("reaping unclaimed guest \(guest.id) of \(owner)")
            closeGuest(guest)
        }
    }

    // An owner that never came back eventually loses its guests.
    private func expiredGuestsLocked() -> [Pane] {
        let online = Set(peerRemotes.compactMap(\.peerOwner))
        let now = Date()
        return guests.values.filter { guest in
            guard let owner = guest.meta.guestOf, !online.contains(owner),
                  let seen = guestLastSeen[owner] else { return false }

            return now.timeIntervalSince(seen) > Self.guestTTL
        }
    }

    private func sendToPeers(owner: String?, tag: MsgTag, json: some Codable & Sendable) {
        lock.lock()
        let targets = peerRemotes.filter { $0.peerOwner == owner }
        lock.unlock()
        for r in targets { _ = r.conn.send(tag: tag, json: json) }
    }

    // MARK: Proxies (a pane in this layout whose pty runs on a peer)

    // The pane takes this layout's slot now; its pty is made on the peer, so
    // it is admitted once the peer answers.
    private func createProxy(_ requester: Conn, _ req: CreatePane, meta: PaneMeta) {
        let hostName = meta.host
        guard let link = peers.link(for: hostName), link.isUp else {
            release(meta.id)
            _ = requester.send(tag: .errorReply, json: ErrorReply(
                message: "host \(hostName) is offline", reqID: req.reqID))
            return
        }

        let ask = CreatePane(rect: meta.rect, cwd: req.cwd, name: req.name, command: req.command)
        link.create(ask) { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure(let why):
                release(meta.id)
                _ = requester.send(tag: .errorReply, json: ErrorReply(
                    message: "\(hostName): \(why)", reqID: req.reqID))
            case .success(let guest):
                let proxy = RemotePane(meta: meta, hostName: hostName, remoteID: guest.id)
                proxy.meta.cwd = guest.cwd
                lock.lock()
                proxies[hostName, default: [:]][guest.id] = proxy
                lock.unlock()
                attachProxy(proxy, link, guest.id)
                admit(proxy, at: meta.rect, req)
            }
        }
    }

    private func release(_ id: PaneID) {
        lock.lock()
        reserved.removeValue(forKey: id)
        lock.unlock()
    }

    // Subscribe to the guest's bytes at the size the canvas last gave it.
    private func attachProxy(_ proxy: RemotePane, _ link: PeerLink, _ guestID: PaneID) {
        proxy.bind(link: link, remoteID: guestID)
        let size = proxy.size
        link.attach(guestID, cols: size.cols, rows: size.rows)
        setLink(proxy, .up)
    }

    private enum LinkState {
        case up, down
    }

    private func setLink(_ pane: Pane, _ state: LinkState) {
        let offline = state == .down
        lock.lock()
        guard pane.meta.offline != offline else {
            lock.unlock()
            return
        }

        pane.meta.offline = offline
        let meta = pane.meta
        scheduleSaveLocked()
        lock.unlock()
        broadcast(tag: .paneMeta, json: meta)
    }

    private func forgetProxyLocked(_ pane: Pane) {
        guard let proxy = pane as? RemotePane, let remote = proxy.remoteID else { return }

        proxies[proxy.hostName]?.removeValue(forKey: remote)
    }

    private func proxiesLocked(of host: String) -> [RemotePane] {
        panes.values.compactMap { $0 as? RemotePane }.filter { $0.hostName == host }
    }

    // The guest is gone (peer restarted, or reaped): same slot, fresh shell.
    private func respawn(_ proxy: RemotePane, _ link: PeerLink) {
        let ask = CreatePane(rect: proxy.meta.rect, cwd: proxy.meta.cwd, name: proxy.meta.name)
        link.create(ask) { [weak self] result in
            guard let self, case .success(let guest) = result else { return }

            lock.lock()
            let stillHere = panes[proxy.id] != nil
            if stillHere {
                if let old = proxy.remoteID {
                    proxies[proxy.hostName]?.removeValue(forKey: old)
                }
                proxies[proxy.hostName, default: [:]][guest.id] = proxy
            }
            lock.unlock()

            // Closed while the guest was being made: don't leave it behind.
            guard stillHere else {
                link.close(guest.id)
                return
            }
            attachProxy(proxy, link, guest.id)
        }
    }
}

// MARK: - Peer links

extension Server: PeerLinkDelegate {
    func peerUp(_ link: PeerLink, welcome: Welcome) {
        let name = link.host.name
        guard peers.link(for: name) === link else { return }

        let alive = Set(welcome.guests.map(\.id))
        lock.lock()
        let mine = proxiesLocked(of: name)
        // Registered, not admitted yet: its guest is alive but it isn't in `mine`.
        let inFlight = Set((proxies[name] ?? [:]).keys).intersection(alive)
        lock.unlock()

        // Claim first: the host reaps every guest of ours we don't list, and
        // the respawns below must not be among the unlisted.
        let kept = mine.filter { $0.remoteID.map(alive.contains) == true }
        link.claim(Array(inFlight.union(kept.compactMap(\.remoteID))))

        for proxy in kept {
            guard let id = proxy.remoteID else { continue }

            attachProxy(proxy, link, id)
        }
        for proxy in mine where !kept.contains(where: { $0 === proxy }) {
            respawn(proxy, link)
        }
        broadcast(tag: .peerState, json: PeerInfo(name: name, up: true))
    }

    func peerDown(_ link: PeerLink) {
        let name = link.host.name
        // A replaced link's late drop must not undo its successor's attach.
        if let current = peers.link(for: name), current !== link { return }

        lock.lock()
        let mine = proxiesLocked(of: name)
        lock.unlock()

        for proxy in mine {
            setLink(proxy, .down)
        }
        broadcast(tag: .peerState, json: PeerInfo(name: name, up: false))
    }

    func peerOutput(_ link: PeerLink, id: PaneID, data: Data, source: PeerOutput) {
        lock.lock()
        let proxy = proxies[link.host.name]?[id]
        lock.unlock()
        guard let proxy else { return }

        // A replay onto existing history is a re-sync after a drop (or a
        // fresh shell in the slot): swap the ring, and reset connected
        // canvases before redrawing, else the snapshot lands on top of the
        // old screen and the bytes missed while down never show.
        if source == .replay, proxy.ring.count > 0 {
            lock.lock()
            proxy.ring.reset()
            lock.unlock()
            fanOut(pane: proxy, data: Self.terminalReset + data)
            return
        }
        fanOut(pane: proxy, data: data)
    }

    func peerMeta(_ link: PeerLink, meta: PaneMeta) {
        lock.lock()
        guard let proxy = proxies[link.host.name]?[meta.id] else {
            lock.unlock()
            return
        }

        // Only what the peer observes; slot, name and groups are ours.
        proxy.meta.cwd = meta.cwd
        proxy.meta.proc = meta.proc
        proxy.meta.title = meta.title
        proxy.meta.repoRoot = meta.repoRoot
        proxy.meta.worktree = meta.worktree
        let updated = proxy.meta
        scheduleSaveLocked()
        lock.unlock()
        broadcast(tag: .paneMeta, json: updated)
    }

    func peerExit(_ link: PeerLink, id: PaneID, code: Int32) {
        lock.lock()
        let proxy = proxies[link.host.name]?[id]
        lock.unlock()
        guard let proxy else { return }

        paneDied(proxy, code: code)
    }
}
