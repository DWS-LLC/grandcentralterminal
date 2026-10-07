// Unix-socket server: accepts UI clients, parses frames, mutates panes,
// fans pane output out to subscribers.

import Foundation
import Common

// A connected UI plus its pane subscriptions.
final class Remote: @unchecked Sendable {
    let conn: Conn
    var subs = Set<PaneID>()
    init(conn: Conn) { self.conn = conn }
}

final class Server {
    private let state: StateStore
    private let sockPath: String
    private let lock = NSLock()  // guards panes + remotes

    private var panes = [PaneID: Pane]()
    private var remotes = [Remote]()

    init(state: StateStore, sockPath: String) {
        self.state = state
        self.sockPath = sockPath
    }

    func run() {
        // Existing panes from a previous life: respawn their shells.
        for meta in state.load() {
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

        guard remote.conn.send(tag: .welcome, json: welcomePayload()) else { return }
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
            lock.lock(); defer { lock.unlock() }
            guard let pane = panes[req.id] else { return }
            pane.meta.rect = req.rect
            scheduleSaveLocked()

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
            lock.unlock()
            // The reader thread unblocks with EIO once the shell dies; its
            // paneDied becomes a no-op (untracked), so broadcast here.
            pane.terminate()
            broadcast(tag: .paneExit, json: PaneExit(id: req.id, code: -1))
            scheduleSaveLocked()

        default:
            break
        }
    }

    private func welcomePayload() -> Welcome {
        lock.lock(); defer { lock.unlock() }
        return Welcome(panes: panes.values
            .sorted { $0.id.uuid.uuidString < $1.id.uuid.uuidString }
            .map(\.meta))
    }

    private func createPane(_ requester: Conn, _ req: CreatePane) {
        let cwd = req.cwd ?? NSHomeDirectory()
        let meta = PaneMeta(id: PaneID(), rect: req.rect, name: req.name,
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
        lock.lock(); defer { lock.unlock() }
        for r in remotes where r.subs.contains(pane.id) {
            _ = r.conn.sendData(tag: .outputPane, paneID: pane.id, data: data)
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
        lock.unlock()
        scheduleSaveLocked()
    }

    private func broadcast(tag: MsgTag, json: some Codable & Sendable) {
        lock.lock(); defer { lock.unlock() }
        for r in remotes { _ = r.conn.send(tag: tag, json: json) }
    }

    private func scheduleSaveLocked() {
        let metas = panes.values.map(\.meta)
        state.scheduleSave(metas)
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
        let metas = panes.values.map(\.meta)
        lock.unlock()
        if dirty { state.scheduleSave(metas) }
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
