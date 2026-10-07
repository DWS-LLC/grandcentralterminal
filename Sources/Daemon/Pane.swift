// One pane: a PTY owned by the daemon, its shell, scrollback ring,
// and subscriber fan-out.

import Foundation
import Common
import ProcInfo

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
        if let cmd = spawnCommand, !cmd.isEmpty {
            return cmd.split(separator: " ").map(String.init)
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return [shell, "-l"]
    }

    // Spawn the shell on a fresh PTY seeded with the current meta.
    // The child is ptyexec: it takes the session, grabs the controlling
    // terminal, and execs the shell. Without the ctty, TIOCSWINSZ's
    // SIGWINCH and tty signals (^C, ^Z, job control) never reach children.
    func spawn(cols: UInt16, rows: UInt16) throws {
        let m = posix_openpt(O_RDWR | O_NOCTTY)
        guard m >= 0 else { throw SpawnError(code: errno) }
        masterFD = m
        guard grantpt(m) == 0, unlockpt(m) == 0 else { throw SpawnError(code: errno) }
        var name = [CChar](repeating: 0, count: 128)
        guard ptsname_r(m, &name, 128) == 0 else { throw SpawnError(code: errno) }
        let slavePath = String(cString: name)

        // Seed the window size before the shell starts; keep the master out
        // of the child via cloexec (ptyexec opens the slave itself).
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(m, TIOCSWINSZ, &ws)
        _ = fcntl(m, F_SETFD, FD_CLOEXEC)

        let helper = Pane.helperPath()
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw SpawnError(code: ENOENT)
        }
        let args = [helper, slavePath, meta.cwd, "--"] + spawnArgs

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

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
        // Accidental inheritance: tool/launcher environments set NO_COLOR=1
        // for their own output; panes are new terminals and should color.
        env.removeValue(forKey: "NO_COLOR")
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "tmuxInfiniteCanvas"
        // GUI-launched daemons inherit launchd's sparse env: no locale,
        // which degrades htop et al. to ASCII/monochrome output.
        if env["LANG"] == nil || env["LANG"]?.hasSuffix("UTF-8") != true {
            env["LANG"] = "en_US.UTF-8"
        }
        return env
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
            if fd >= 0 { _ = Darwin.close(fd) }
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
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
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
