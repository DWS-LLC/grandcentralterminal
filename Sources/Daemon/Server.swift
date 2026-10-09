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
    init(conn: Conn) { self.conn = conn }
}

final class Server {
    private let state: StateStore
    private let sockPath: String
    private let lock = NSLock()  // guards panes + groups + remotes

    private var panes = [PaneID: Pane]()
    // Group ownership: sanitized once on write; member ids pruned to
    // live panes on load and on every pane exit/close.
    private var groups = [GroupID: GroupMeta]()
    private var remotes = [Remote]()

    init(state: StateStore, sockPath: String) {
        self.state = state
        self.sockPath = sockPath
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
            groups[g.id] = g
        }

        unlink(sockPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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

        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 {
                if errno == EINTR { continue }
                log("accept failed: \(errno)")
                return
            }
            _ = fcntl(cfd, F_SETFD, FD_CLOEXEC)
            let remote = Remote(conn: Conn(fd: cfd))
            lock.lock()
            remotes.append(remote)
            lock.unlock()
            Thread(block: { [weak self] in self?.serve(remote) }).start()
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

        // Don't bail if the client is already gone (e.g. `stop` sends
        // killDaemon and exits before we write): fall through to the read
        // loop so a queued frame still lands instead of being dropped.
        _ = remote.conn.send(tag: .welcome, json: welcomePayload())
        remote.conn.readLoop { [weak self] frame in
            self?.handle(remote, frame)
        }
    }

    private func handle(_ remote: Remote, _ frame: Frame) {
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
                _ = remote.conn.sendData(tag: .outputPane, paneID: req.id, data: snap)
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
            let obstacles = GroupLayout.moveObstacles(
                moving: req.id, memberOf: memberOf.map { Set([$0]) } ?? [],
                panes: rects, groups: metas,
                allowOverlap: req.allowOverlap)
            rect = Overlap.resolve(rect, obstacles: obstacles)
            // Invariant: a member's new rect must not grow its group's
            // bounds over anything foreign — another group's bounds or a
            // loose pane. Slide along the grown bounds first (mirrors the
            // canvas static drags so the stream converges); hold the
            // current rect only when truly wedged.
            if let memberOf,
               GroupLayout.grownClash(moving: req.id, memberOf: memberOf,
                                      candidate: rect,
                                      panes: rects, groups: metas) {
                let slid = GroupLayout.slideGrownRect(
                    candidate: rect,
                    moving: req.id, memberOf: memberOf,
                    panes: rects, groups: metas)
                rect = GroupLayout.grownClash(
                    moving: req.id, memberOf: memberOf, candidate: slid,
                    panes: rects, groups: metas)
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
            for g in pruned { broadcast(tag: .groupMeta, json: g) }
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
            func clearAdding(_ id: PaneID) -> Bool {
                var trial = g
                trial.members = admitted + [id]
                var trialGroups = groups
                trialGroups[req.id] = trial
                guard let grown = GroupLayout.bounds(
                    groups: trialGroups, panes: rects)[req.id] else {
                    return true
                }
                let liveBounds = GroupLayout.bounds(groups: groups,
                                                    panes: rects)
                for (gid, b) in liveBounds where gid != req.id {
                    if Overlap.overlaps(grown, b) { return false }
                }
                for (pid, r) in rects
                    where pid != id && !admittedSet.contains(pid) {
                    if Overlap.overlaps(grown, r) { return false }
                }
                return true
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
            // membership).
            let fresh = Set(admitted)
            var evicted = [GroupMeta]()
            for (id, var other) in groups where id != req.id {
                let before = other.members.count
                other.members.removeAll { fresh.contains($0) }
                if other.members.count != before {
                    groups[id] = other
                    evicted.append(other)
                }
            }
            groups[req.id] = g
            let updated = g
            let afterUpdate = snapshotLocked()
            lock.unlock()
            for e in evicted { broadcast(tag: .groupMeta, json: e) }
            broadcast(tag: .groupMeta, json: updated)
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
        // bounds stay clear of foreign groups and loose panes.
        let gid = GroupID()
        var admitted = [PaneID]()
        for id in wanted {
            let trial = GroupMeta(id: gid, members: admitted + [id])
            var trialGroups = groups
            trialGroups[gid] = trial
            guard let grown = GroupLayout.bounds(
                groups: trialGroups, panes: rects)[gid] else { continue }
            let liveBounds = GroupLayout.bounds(groups: groups, panes: rects)
            var clash = liveBounds.contains {
                Overlap.overlaps(grown, $0.value)
            }
            if !clash {
                let inside = Set(admitted + [id])
                clash = rects.contains {
                    $0.key != id && !inside.contains($0.key)
                        && Overlap.overlaps(grown, $0.value)
                }
            }
            if !clash { admitted.append(id) }
        }
        let fresh = Set(admitted)
        for (id, var other) in groups {
            let before = other.members.count
            other.members.removeAll { fresh.contains($0) }
            if other.members.count != before {
                groups[id] = other
                let m = other
                broadcastLocked(tag: .groupMeta, json: m)
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

    // Drop a dead pane from every group; returns touched groups for
    // broadcast.
    @discardableResult
    private func prunePaneLocked(_ id: PaneID) -> [GroupMeta] {
        var touched = [GroupMeta]()
        for (gid, var g) in groups where g.members.contains(id) {
            g.members.removeAll { $0 == id }
            groups[gid] = g
            touched.append(g)
        }
        return touched
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
            moving: req.id, panes: rects, groups: metas)
        let target = Rect(x: b.x + req.dx, y: b.y + req.dy, w: b.w, h: b.h)
        let clean = Overlap.resolve(target, obstacles: obstacles)
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
        // New panes are groupless: group bounds always block, even when
        // the client allows overlap.
        lock.lock()
        let rects = paneRectsLocked()
        let metas = groupMetasLocked()
        let rect: Rect = {
            let obstacles = GroupLayout.creationObstacles(
                panes: req.allowOverlap ? [] : Array(rects.values),
                groups: metas, paneRects: rects,
                allowOverlap: req.allowOverlap)
            // allowOverlap + no groups = untouched fast path.
            guard !obstacles.isEmpty else { return req.rect }
            return Overlap.resolve(req.rect, obstacles: obstacles)
        }()
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
        lock.unlock()
        startPaneThreads(pane)

        broadcast(tag: .paneCreated, json: PaneCreated(meta: pane.meta))
        scheduleSaveLocked()
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
        for g in pruned { broadcast(tag: .groupMeta, json: g) }
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
