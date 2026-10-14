// Unix-socket server: accepts UI clients, parses frames, mutates panes,
// fans pane output out to subscribers.

import Foundation
import Common

// A connected UI plus its pane subscriptions.
final class Remote: @unchecked Sendable {
    let conn: Conn
    var subs = Set<PaneID>()
    // Set when a send fails (slow/dead client): skips future fan-out until
    // the client drains or disconnects. Prevents one stalled subscriber
    // from wedging every pane reader on the server lock.
    var wedged = false
    // Unix peers start trusted; TCP peers become trusted only after the
    // token hello. Untrusted peers get one hello chance, then dropped.
    var trusted = true
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
    // Group ownership: sanitized once on write; member ids pruned to
    // live panes on load and on every pane exit/close.
    private var groups = [GroupID: GroupMeta]()
    private var remotes = [Remote]()

    init(state: StateStore, sockPath: String, tcpPort: UInt16? = nil,
         token: String = "") {
        self.state = state
        self.sockPath = sockPath
        self.tcpPort = tcpPort
        self.token = token
    }

    func run() {
        // Existing panes from a previous life: respawn their shells.
        // Groups restore with members pruned to live panes.
        let saved = state.load()
        for meta in saved.panes {
            var fresh = meta
            fresh.exited = false
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
    private func acceptConn(_ cfd: Int32, trusted: Bool) {
        let remote = Remote(conn: Conn(fd: cfd))
        remote.trusted = trusted
        lock.lock()
        remotes.append(remote)
        lock.unlock()
        Thread(block: { [weak self] in self?.serve(remote) }).start()
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
        }

        // Don't bail if the client is already gone (e.g. `stop` sends
        // killDaemon and exits before we write): fall through to the read
        // loop so a queued frame still lands instead of being dropped.
        _ = remote.conn.send(tag: .welcome, json: welcomePayload())
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
            _ = remote.conn.send(tag: .welcome, json: welcomePayload())

        case .killDaemon:
            shutdown()

        case .createPane:
            guard let req: CreatePane = frame.decode() else { return }
            createPane(remote.conn, req)

        case .attachPane:
            guard let req: AttachPane = frame.decode() else { return }
            lock.lock(); defer { lock.unlock() }
            guard let pane = panes[req.id] else {
                _ = remote.conn.send(tag: .errorReply,
                                     json: ErrorReply(message: "no such pane"))
                return
            }
            pane.resize(cols: req.cols, rows: req.rows)
            remote.subs.insert(req.id)
            // Ring first so replay lands before any live bytes; fanOut and
            // this are serialized by the server lock.
            let snap = pane.ring.snapshot()
            if !snap.isEmpty {
                _ = remote.conn.sendData(tag: .replayPane, paneID: req.id, data: snap)
            }

        case .detachPane:
            guard let req: PaneRef = frame.decode() else { return }
            lock.lock(); defer { lock.unlock() }
            remote.subs.remove(req.id)

        case .inputPane:
            guard let id = frame.paneID, let pane = panes[id] else { return }
            pane.writeStdin(frame.data)

        case .resizePane:
            guard let req: ResizePane = frame.decode() else { return }
            lock.lock(); defer { lock.unlock() }
            panes[req.id]?.resize(cols: req.cols, rows: req.rows)

        case .renamePane:
            guard let req: RenamePane = frame.decode() else { return }
            lock.lock(); defer { lock.unlock() }
            guard let pane = panes[req.id] else { return }
            pane.meta.name = req.name
            for r in remotes { _ = r.conn.send(tag: .paneMeta, json: pane.meta) }
            scheduleSaveLocked()

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
            rect = Overlap.resolve(rect, obstacles: obstacles, gap: req.gap)
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
            let saved = snapshotLocked()
            lock.unlock()
            for r in targets { _ = r.conn.send(tag: .paneMeta, json: meta) }
            state.scheduleSave(saved)

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
            guard let pane = panes[req.id] else { lock.unlock(); return }
            panes.removeValue(forKey: req.id)
            for r in remotes { r.subs.remove(req.id) }
            let pruned = prunePaneLocked(req.id)
            let saved = snapshotLocked()
            lock.unlock()
            // The reader thread unblocks with EIO once the shell dies; its
            // paneDied becomes a no-op (untracked), so broadcast here.
            pane.terminate()
            broadcast(tag: .paneExit, json: PaneExit(id: req.id, code: -1))
            for g in pruned.touched { broadcast(tag: .groupMeta, json: g) }
            for gid in pruned.emptied { broadcast(tag: .groupExit, json: GroupRef(id: gid)) }
            state.scheduleSave(saved)

        case .createGroup:
            guard let req: CreateGroup = frame.decode() else { return }
            lock.lock()
            let meta = makeGroupLocked(name: req.name, color: req.color,
                                       members: req.members)
            let afterCreate = snapshotLocked()
            lock.unlock()
            broadcast(tag: .groupCreated, json: GroupCreated(meta: meta))
            state.scheduleSave(afterCreate)

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
            g.color = GroupStyle.sanitizedColor(req.color) ?? g.color
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
            let afterUpdate = snapshotLocked()
            lock.unlock()
            for e in evicted { broadcast(tag: .groupMeta, json: e) }
            if let updated { broadcast(tag: .groupMeta, json: updated) }
            for gid in emptied { broadcast(tag: .groupExit, json: GroupRef(id: gid)) }
            state.scheduleSave(afterUpdate)
        case .deleteGroup:
            guard let req: GroupRef = frame.decode() else { return }
            lock.lock()
            guard groups.removeValue(forKey: req.id) != nil else {
                lock.unlock(); return
            }
            let afterDelete = snapshotLocked()
            lock.unlock()
            broadcast(tag: .groupExit, json: req)
            state.scheduleSave(afterDelete)

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
                var rect = Overlap.resolve(pane.meta.rect, obstacles: obstacles, gap: req.gap)
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
            let saved = snapshotLocked()
            lock.unlock()
            broadcast(tag: .paneMeta, json: meta)
            state.scheduleSave(saved)

        case .dumpPane:
            // Read-only ring snapshot. Never subscribes, never resizes:
            // agents poll this for background-task inspection.
            guard let req: DumpPane = frame.decode() else { return }
            lock.lock()
            guard let pane = panes[req.id] else {
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
            let tail = want == total ? snap : snap.subdata(in: (total - want)..<total)
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

    private func welcomePayload() -> Welcome {
        lock.lock(); defer { lock.unlock() }
        return Welcome(panes: panes.values
            .sorted { $0.id.uuid.uuidString < $1.id.uuid.uuidString }
            .map(\.meta), groups: Array(groups.values))
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
        SavedState(panes: panes.values.map(\.meta),
                   groups: Array(groups.values))
    }

    // Create + sanitize: unknown ids dropped, members evicted from other
    // groups (single membership), color validated, empty name cleared.
    private func makeGroupLocked(name: String?, color: String?,
                                 members: [PaneID]) -> GroupMeta {
        let live = Set(panes.keys)
        let wanted = members.filter { live.contains($0) }
        let rects = paneRectsLocked()
        // Admit in request order, keeping each only while the trial
        // bounds stay clear of foreign groups and non-joining panes.
        // `wanted` panes are joining, not foreign (same fix as
        // updateGroup: padding overhangs of adjacent joiners must not
        // refuse each other).
        let gid = GroupID()
        let joining = Set(wanted)
        var admitted = [PaneID]()
        for id in wanted {
            let clear = GroupLayout.admits(
                id, into: gid, members: admitted, joining: joining,
                groups: groups, panes: rects)
            if clear { admitted.append(id) }
        }
        let fresh = Set(admitted)
        for (id, var other) in groups {
            let before = other.members.count
            other.members.removeAll { fresh.contains($0) }
            if other.members.count != before {
                if other.members.isEmpty {
                    groups.removeValue(forKey: id)
                    broadcastLocked(tag: .groupExit, json: GroupRef(id: id))
                } else {
                    groups[id] = other
                    let m = other
                    broadcastLocked(tag: .groupMeta, json: m)
                }
            }
        }
        let g = GroupMeta(id: gid,
                          name: GroupStyle.sanitizedName(name),
                          color: GroupStyle.sanitizedColor(color)
                            ?? GroupStyle.palette[groups.count % GroupStyle.palette.count],
                          members: admitted)
        groups[g.id] = g
        return g
    }

    // Drop a dead pane from every group. Groups left with no live
    // members are deleted (empty groups don't linger in menus);
    // returns survivors for groupMeta broadcast, dead ids for groupExit.
    @discardableResult
    private func prunePaneLocked(_ id: PaneID) -> (touched: [GroupMeta], emptied: [GroupID]) {
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
        return (touched, emptied)
    }

    private func broadcastLocked(tag: MsgTag, json: some Codable & Sendable) {
        for r in remotes { _ = r.conn.send(tag: tag, json: json) }
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
        let clean = Overlap.resolve(target, obstacles: obstacles, gap: req.gap)
        let dx = clean.x - b.x, dy = clean.y - b.y
        var updated = [PaneMeta]()
        for id in members {
            guard let pane = panes[id] else { continue }
            var r = pane.meta.rect
            r.x += dx; r.y += dy
            pane.meta.rect = r
            updated.append(pane.meta)
        }
        let saved = snapshotLocked()
        let targetsRemotes = remotes
        lock.unlock()
        for m in updated {
            for r in targetsRemotes { _ = r.conn.send(tag: .paneMeta, json: m) }
        }
        state.scheduleSave(saved)
    }

    private func createPane(_ requester: Conn, _ req: CreatePane) {
        // New panes are groupless unless joinGroup asks for admission
        // (directional split from a grouped pane). Joiners land FLUSH at
        // the requested rect — only foreign group bounds deflect
        // placement; loose panes in the way are shoved aside along the
        // split axis at admit time (cascade included). Foreign-group
        // clash still refuses the join (groupless pane, no error).
        lock.lock()
        let rects = paneRectsLocked()
        let metas = groupMetasLocked()
        let floating = floatingLocked()
        let rect: Rect
        if req.joinGroup != nil {
            var obstacles = [Rect]()
            for (gid, b) in GroupLayout.bounds(groups: metas, panes: rects)
                where gid != req.joinGroup {
                obstacles.append(b)
            }
            rect = obstacles.isEmpty ? req.rect
                : Overlap.resolve(req.rect, obstacles: obstacles, gap: req.gap)
        } else {
            let obstacles = GroupLayout.creationObstacles(
                paneRects: rects,
                groups: metas,
                allowOverlap: req.allowOverlap,
                floating: floating)
            rect = obstacles.isEmpty ? req.rect
                : Overlap.resolve(req.rect, obstacles: obstacles, gap: req.gap)
        }
        lock.unlock()
        let cwd = req.cwd ?? NSHomeDirectory()
        let meta = PaneMeta(id: PaneID(), rect: rect, name: req.name,
                            cwd: cwd, host: "local", title: nil, exited: false)
        let pane = Pane(meta: meta, command: req.command)
        do {
            try pane.spawn(cols: 80, rows: 24)
        } catch {
            log("spawn failed: \(error)")
            _ = requester.send(tag: .errorReply,
                               json: ErrorReply(message: "spawn failed: \(error)"))
            return
        }

        lock.lock()
        panes[pane.id] = pane
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
                        floating: floatingLocked(), gap: req.gap)
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
        let saved = snapshotLocked()
        let targets = remotes
        lock.unlock()
        startPaneThreads(pane)

        broadcast(tag: .paneCreated, json: PaneCreated(meta: pane.meta))
        for m in movedMetas {
            broadcast(tag: .paneMeta, json: m)
        }
        if let joined {
            for r in targets { _ = r.conn.send(tag: .groupMeta, json: joined) }
        }
        state.scheduleSave(saved)
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
        pane.startReading({ [weak self] pane, data in
            self?.fanOut(pane: pane, data: data)
        }, { [weak self] pane in
            self?.paneDied(pane)
        })
    }

    private func fanOut(pane: Pane, data: Data) {
        lock.lock()
        var targets = [Remote]()
        for r in remotes where !r.wedged && r.subs.contains(pane.id) {
            targets.append(r)
        }
        lock.unlock()
        // Blocking socket writes OUTSIDE the server lock: a full client
        // buffer stalls only this pane's reader, never control traffic.
        for r in targets {
            if !r.conn.sendData(tag: .outputPane, paneID: pane.id, data: data) {
                lock.lock()
                r.wedged = true
                lock.unlock()
            }
        }
    }

    // Called from the pane's reader thread (EOF/EIO) and from housekeep.
    // The reader thread owns closing the master fd; close() on macOS does
    // not unblock a blocked read, so we must not close here.
    private func paneDied(_ pane: Pane) {
        lock.lock()
        let stillTracked = panes[pane.id] != nil
        pane.markExited()
        lock.unlock()
        guard stillTracked else { return }

        broadcast(tag: .paneExit, json: PaneExit(id: pane.id, code: 0))

        lock.lock()
        panes.removeValue(forKey: pane.id)
        let pruned = prunePaneLocked(pane.id)
        let saved = snapshotLocked()
        lock.unlock()
        for g in pruned.touched { broadcast(tag: .groupMeta, json: g) }
        for gid in pruned.emptied { broadcast(tag: .groupExit, json: GroupRef(id: gid)) }
        state.scheduleSave(saved)
    }

    private func broadcast(tag: MsgTag, json: some Codable & Sendable) {
        lock.lock(); defer { lock.unlock() }
        for r in remotes { _ = r.conn.send(tag: tag, json: json) }
    }

    private func scheduleSaveLocked() {
        state.scheduleSave(snapshotLocked())
    }

    private func housekeep() {
        var dirty = false
        lock.lock()
        for pane in panes.values {
            if pane.pollExit() != nil {
                dirty = true
                Task { [weak self] in self?.paneDied(pane) }
            } else if let cwd = pane.pollCWD() {
                pane.meta.cwd = cwd
                dirty = true
                for r in remotes { _ = r.conn.send(tag: .paneMeta, json: pane.meta) }
            }
        }
        let saved = snapshotLocked()
        lock.unlock()
        if dirty { state.scheduleSave(saved) }
    }

    func shutdown() {
        lock.lock()
        let all = Array(panes.values)
        panes.removeAll()
        lock.unlock()
        for p in all { p.terminate() }
        exit(0)
    }
}
