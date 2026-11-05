// One pane: a PTY owned by the daemon, its shell, scrollback ring,
// and subscriber fan-out.

import Foundation
import Common
import ProcInfo

#if os(Linux)
// Glibc's Swift import hides the X/Open PTY functions (they need
// feature-test macros); declare them straight from libc.
@_silgen_name("posix_openpt") func gct_posix_openpt(_ flags: Int32) -> Int32
@_silgen_name("grantpt") func gct_grantpt(_ fd: Int32) -> Int32
@_silgen_name("unlockpt") func gct_unlockpt(_ fd: Int32) -> Int32
@_silgen_name("ptsname_r") func gct_ptsname_r(_ fd: Int32, _ buf: UnsafeMutablePointer<CChar>, _ len: UInt) -> Int32
#endif

final class Pane {
    let id: PaneID
    var meta: PaneMeta
    let ring = Ring(cap: 8 << 20)  // 8 MiB scrollback

    private(set) var masterFD: Int32 = -1
    private(set) var pid: pid_t = 0
    private var exitedFlag = false
    // waitpid collected the child: pid may now belong to someone else.
    private var reapedFlag = false
    private let lock = NSLock()

    // args used to spawn (for respawn-on-daemon-restart)
    let spawnCommand: String?

    // A foreground command is reported once two polls in a row agree: a
    // one-second `ls` must not rename the pane.
    private struct ProcSample { var line: String? }
    private var pendingProc: ProcSample?
    private var probedCwd: String?

    var exited: Bool {
        lock.lock(); defer { lock.unlock() }
        return exitedFlag
    }

    var reaped: Bool {
        lock.lock(); defer { lock.unlock() }
        return reapedFlag
    }

    // A hung-up session gets this long before SIGKILL.
    private static let hangupGrace: TimeInterval = 2

    // Keystrokes and pastes queue here; a writer thread drains them so a
    // pty nobody reads (raw-mode app, busy) never blocks the client's
    // request loop. Past the cap, input drops rather than eat memory.
    private let inbox = NSCondition()
    private var inboxChunks = [Data]()
    private var inboxBytes = 0
    private var inboxOpen = true
    private static let inboxCap = 32 << 20

    init(meta: PaneMeta, command: String?) {
        self.id = meta.id
        self.meta = meta
        self.spawnCommand = command
    }

    // Last ref gone, reader thread included: nobody can write or resize
    // through the fd, so its number can't be reused under them.
    deinit {
        if masterFD >= 0 { _ = closeSocket(masterFD) }
    }

    var spawnArgs: [String] {
        // One-shot commands run through the user's login shell, not split
        // on spaces: agents pass real shell syntax (`&&`, quotes, pipes).
        // Empty = interactive login shell. Either way the pane exits when
        // the command does (tmux-like); `send` drives a live shell instead.
        // Default is $SHELL, else the passwd shell, else zsh (macOS) /
        // bash (Linux, which rarely has zsh). NEVER an empty/hardcoded
        // wrong shell: bash-as-login prints the "default is now zsh"
        // warning on macOS and skips the user's real rc files.
        let shell: String
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty {
            shell = s
        } else if let pw = getpwuid(getuid()), let cs = pw.pointee.pw_shell {
            shell = String(cString: cs)
        } else {
#if os(Linux)
            shell = "/bin/bash"
#else
            shell = "/bin/zsh"
#endif
        }
        if let cmd = spawnCommand, !cmd.isEmpty {
            return [shell, "-l", "-c", cmd]
        }
        return [shell, "-l"]
    }

    // Spawn the shell on a fresh PTY seeded with the current meta.
    // The child is ptyexec: it takes the session, grabs the controlling
    // terminal, and execs the shell. Without the ctty, TIOCSWINSZ's
    // SIGWINCH and tty signals (^C, ^Z, job control) never reach children.
    func spawn(cols: UInt16, rows: UInt16) throws {
#if os(Linux)
        let m = gct_posix_openpt(Int32(O_RDWR | O_NOCTTY))
#else
        let m = posix_openpt(O_RDWR | O_NOCTTY)
#endif
        guard m >= 0 else { throw SpawnError(code: errno) }
        masterFD = m
#if os(Linux)
        guard gct_grantpt(m) == 0, gct_unlockpt(m) == 0 else { throw SpawnError(code: errno) }
#else
        guard grantpt(m) == 0, unlockpt(m) == 0 else { throw SpawnError(code: errno) }
#endif
        var name = [CChar](repeating: 0, count: 128)
#if os(Linux)
        guard gct_ptsname_r(m, &name, 128) == 0 else { throw SpawnError(code: errno) }
#else
        guard ptsname_r(m, &name, 128) == 0 else { throw SpawnError(code: errno) }
#endif
        let slavePath = String(cString: name)

        // Seed the window size before the shell starts; keep the master out
        // of the child via cloexec (ptyexec opens the slave itself).
        // ioctl wants c_ulong on Glibc, UInt on Darwin — one cast each.
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
#if os(Linux)
        _ = ioctl(m, UInt(TIOCSWINSZ), &ws)
#else
        _ = ioctl(m, TIOCSWINSZ, &ws)
#endif
        _ = fcntl(m, F_SETFD, FD_CLOEXEC)

        let helper = Pane.helperPath()
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw SpawnError(code: ENOENT)
        }
        let args = [helper, slavePath, meta.cwd, "--"] + spawnArgs

#if os(Linux)
        // Glibc's posix_spawnattr_t is a value struct, not a pointer.
        var attr = posix_spawnattr_t()
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
#else
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Close every fd in the child. Per-fd FD_CLOEXEC races a concurrent
        // spawn (another pane's master leaks in); ptyexec opens its own stdio.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
#endif

        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0)! }
        cargs.append(nil)
        var cenvp: [UnsafeMutablePointer<CChar>?] = childEnv()
            .sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)")! }
        cenvp.append(nil)
        defer {
            cargs.forEach { free($0) }
            cenvp.forEach { free($0) }
        }

        var pidOut: pid_t = 0
        let rc = posix_spawn(&pidOut, args[0], nil, &attr, &cargs, &cenvp)
        guard rc == 0 else { throw SpawnError(code: rc) }
        pid = pidOut
    }

    // ptyexec lives next to the daemon binary (bin/ staging or app bundle).
    private static func helperPath() -> String {
        var self0 = CommandLine.arguments.first ?? ""
        if !self0.hasPrefix("/") {
            self0 = FileManager.default.currentDirectoryPath + "/" + self0
        }
        let dir = (self0 as NSString).deletingLastPathComponent
        return dir + "/ptyexec"
    }

    private func childEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "GHOSTTY_RESOURCES_DIR")
        // Accidental inheritance: tool/launcher environments set these for
        // their own output; panes are new terminals and must color.
        // NO_COLOR + CLICOLOR=0 + FORCE_COLOR=0 all kill color (observed:
        // Claude Code sessions show monochrome panes until scrubbed).
        env.removeValue(forKey: "NO_COLOR")
        if env["CLICOLOR"] == "0" { env.removeValue(forKey: "CLICOLOR") }
        if env["FORCE_COLOR"] == "0" { env.removeValue(forKey: "FORCE_COLOR") }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "GrandCentralTerminal"
        // Agent/harness hooks: GCT_PANE_ID lets a shell know which pane it
        // is (for `gctd dump $GCT_PANE_ID` self-inspection); GCT_SOCK
        // points gctd's own CLI at this daemon (test/bench isolation
        // overrides flow through instead of hitting the live socket).
        env["GCT_PANE_ID"] = id.uuid.uuidString
        env["GCT_SOCK"] = Pane.sockPathForChildren()
        // GUI-launched daemons inherit launchd's sparse env: no locale,
        // which degrades htop et al. to ASCII/monochrome output.
        if env["LANG"] == nil || env["LANG"]?.hasSuffix("UTF-8") != true {
            env["LANG"] = "en_US.UTF-8"
        }
        return env
    }

    // Socket path the daemon is serving on, passed down so in-pane
    // `gctd` CLI calls reach THIS daemon. Spawned early (before the
    // socket binds), so read the same env override the server used.
    private static func sockPathForChildren() -> String {
        if let p = ProcessInfo.processInfo.environment["GCT_SOCK"],
           !p.isEmpty {
            return p
        }
        return daemonBaseDir() + "/daemon.sock"
    }

    // Reader + writer threads, one each per pane. Both hold the pane
    // strongly: close() on macOS does not unblock a blocked read, so the
    // fd closes in deinit, after both let go.
    func startIO(_ onOutput: @escaping (Pane, Data) -> Void,
                 _ onEOF: @escaping (Pane) -> Void) {
        startWriting()
        let fd = masterFD
        Thread(block: { [self] in
            var buf = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n < 0 && errno == EINTR {
                    continue
                }
                if n <= 0 {
                    break
                }
                // onOutput appends to the ring (see Server.fanOut).
                onOutput(self, Data(buf[0..<n]))
            }
            closeInbox()
            onEOF(self)
        }).start()
    }

    // Queue input for the writer thread; never blocks.
    func writeStdin(_ data: Data) {
        guard !data.isEmpty else { return }
        inbox.lock(); defer { inbox.unlock() }
        guard inboxOpen, inboxBytes + data.count <= Self.inboxCap else { return }

        inboxChunks.append(data)
        inboxBytes += data.count
        inbox.signal()
    }

    private func startWriting() {
        let fd = masterFD
        Thread(block: { [self] in
            while let chunk = nextInput() {
                guard Self.writeAll(fd, chunk) else { break }
            }
            closeInbox()
        }).start()
    }

    // Blocks until input arrives; nil once the pty is gone.
    private func nextInput() -> Data? {
        inbox.lock(); defer { inbox.unlock() }
        while inboxOpen && inboxChunks.isEmpty {
            inbox.wait()
        }
        guard inboxOpen else { return nil }

        let chunk = inboxChunks.removeFirst()
        inboxBytes -= chunk.count
        return chunk
    }

    private func closeInbox() {
        inbox.lock(); defer { inbox.unlock() }
        inboxOpen = false
        inboxChunks.removeAll()
        inboxBytes = 0
        inbox.broadcast()
    }

    // False on a dead pty (EIO once the slave side closes).
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 && errno == EINTR {
                    continue
                }
                if n < 0 {
                    return false
                }
                off += n
            }
            return true
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
#if os(Linux)
        _ = ioctl(masterFD, UInt(TIOCSWINSZ), &ws)
#else
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
#endif
    }

    func markExited() {
        lock.lock()
        exitedFlag = true
        lock.unlock()
    }

    // Hang up like a closed terminal: interactive shells ignore SIGTERM.
    // Shell's group plus the foreground job's; survivors get SIGKILL.
    func terminate() {
        signalGroups(SIGHUP)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.hangupGrace) { [self] in
            signalGroups(SIGKILL)
        }
    }

    // Daemon exit: terminate()'s delayed SIGKILL would never fire, so
    // hang up, wait out the grace (or every reap), then kill stragglers.
    static func terminateAll(_ panes: [Pane]) {
        for p in panes { p.signalGroups(SIGHUP) }

        let deadline = Date().addingTimeInterval(hangupGrace)
        var live = panes
        while !live.isEmpty, Date() < deadline {
            live.removeAll { $0.reaped || $0.pollExit() != nil }
            usleep(reapPollMicros)
        }

        for p in live { p.signalGroups(SIGKILL) }
    }
    private static let reapPollMicros: useconds_t = 50_000

    // Under the lock so a concurrent reap can't hand us a recycled pid.
    private func signalGroups(_ sig: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard pid > 0, !reapedFlag else { return }

        _ = kill(-pid, sig)
        let fg = tcgetpgrp(masterFD)
        if fg > 0 && fg != pid {
            _ = kill(-fg, sig)
        }
    }

    // Reap the child if it exited; returns its exit status once.
    func pollExit() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        guard pid > 0, !reapedFlag else { return nil }

        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == 0 || (r < 0 && errno == EINTR) {
            return nil
        }

        // r < 0 (ECHILD): already gone, nothing left to collect.
        reapedFlag = true
        exitedFlag = true
        guard r == pid else { return -1 }
        return (status & 0o177) == 0 ? (status >> 8) & 0xff : 0
    }

    // Poll the child's cwd; returns it when changed.
    func pollCWD() -> String? {
        guard pid > 0, !exited else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_cwd(pid, &buf, 4096) > 0 else { return nil }
        let cwd = String(cString: buf)
        return cwd != meta.cwd ? cwd : nil
    }

    // Refresh the context auto names and the spring layout feed on:
    // foreground command and git work tree. True when meta changed.
    func pollContext() -> Bool {
        guard pid > 0, !exited else { return false }
        let procChanged = pollProc()
        let repoChanged = pollRepo()
        return procChanged || repoChanged
    }

    // The terminal's foreground process group leads with its own pid. An
    // idle shell reports itself ("-zsh"); AutoName treats shells as idle.
    private func pollProc() -> Bool {
        let fg = tcgetpgrp(masterFD)
        guard fg > 0 else { return false }

        var buf = [CChar](repeating: 0, count: 1024)
        guard proc_cmdline(fg, &buf, 1024) > 0 else { return false }
        let sample = ProcSample(line: String(cString: buf))

        if sample.line == meta.proc {
            pendingProc = nil
            return false
        }

        guard pendingProc.map({ $0.line == sample.line }) == true else {
            pendingProc = sample
            return false
        }

        pendingProc = nil
        meta.proc = sample.line
        return true
    }

    // Linked worktrees re-probe every poll: `git switch` moves HEAD, not cwd.
    private func pollRepo() -> Bool {
        guard meta.cwd != probedCwd || meta.worktree != nil else { return false }
        probedCwd = meta.cwd

        let info = RepoProbe.probe(cwd: meta.cwd)
        guard info?.root != meta.repoRoot || info?.worktree != meta.worktree else { return false }

        meta.repoRoot = info?.root
        meta.worktree = info?.worktree
        return true
    }
}

struct SpawnError: Error, CustomStringConvertible {
    let code: Int32
    var description: String {
        String(cString: strerror(code))
    }
}
