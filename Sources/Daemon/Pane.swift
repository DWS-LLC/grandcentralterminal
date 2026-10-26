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

    init(meta: PaneMeta, command: String?) {
        self.id = meta.id
        self.meta = meta
        self.spawnCommand = command
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
#endif

        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0)! }
        cargs.append(nil)
        var cenvp: [UnsafeMutablePointer<CChar>?] = childEnv()
            .sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)")! }
        cenvp.append(nil)

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

    // Blocking reader: runs on its own thread per pane. Owns closing the
    // master fd: close() on macOS does not unblock a blocked read, so the
    // fd may only be closed here after read() returns.
    func startReading(_ onOutput: @escaping (Pane, Data) -> Void,
                      _ onEOF: @escaping (Pane) -> Void) {
        let fd = masterFD
        Thread(block: { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65_536)
            while let p = self {
                let n = read(fd, &buf, buf.count)
                if n <= 0 {
                    if errno == EINTR { continue }
                    break
                }
                let chunk = Data(buf[0..<n])
                p.ring.append(chunk)
                onOutput(p, chunk)
            }
            if fd >= 0 { _ = closeSocket(fd) }
            onEOF(self ?? Pane.placeholder)
        }).start()
    }

    func writeStdin(_ data: Data) {
        let fd = masterFD
        guard fd >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                off += n
            }
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

    func terminate() {
        guard pid > 0, !exited else { return }
        _ = kill(pid, SIGTERM)
    }

    // Poll whether the child reaped; returns exit status if so.
    func pollExit() -> Int32? {
        guard pid > 0, !exited else { return nil }
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid {
            markExited()
            return (status & 0o177) == 0 ? (status >> 8) & 0xff : 0
        }
        return nil
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

    private func pollRepo() -> Bool {
        guard meta.cwd != probedCwd else { return false }
        probedCwd = meta.cwd

        let info = RepoProbe.probe(cwd: meta.cwd)
        guard info?.root != meta.repoRoot || info?.worktree != meta.worktree else { return false }

        meta.repoRoot = info?.root
        meta.worktree = info?.worktree
        return true
    }
}

// Zero-sized dummy so the reader thread's onEOF can reference a pane
// when self was deallocated mid-read; never fanned out (closed panes
// have no subscribers).
extension Pane {
    static let placeholder = Pane(
        meta: PaneMeta(id: PaneID(), rect: Rect(x: 0, y: 0, w: 0, h: 0),
                       name: nil, cwd: "/", host: "local", title: nil, exited: true),
        command: nil)
}

struct SpawnError: Error, CustomStringConvertible {
    let code: Int32
    var description: String {
        String(cString: strerror(code))
    }
}
