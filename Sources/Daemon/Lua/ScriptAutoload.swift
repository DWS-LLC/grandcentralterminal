// Scripts that start with the daemon: every *.lua in <config dir>/autoload/.
//
//   ~/.config/gct/autoload/notify.lua ──► gctd --sock S lua notify.lua
//                                          └─ stdout+stderr ► script-logs/notify.lua.log
//
// Each runs as its own `gctd lua` process, a plain client of this daemon, so
// the daemon never executes script code and a runaway script costs one
// process, not your shells. The folder is rescanned like the status bar's:
// drop a file in and it starts, save it and it restarts, delete it and it
// stops. A script that fails is retried with a growing delay; one that ends
// cleanly (exit 0) stays done until the file changes.

import Foundation
import Common

private final class Entry {
    let file: String
    var stamp: Date
    var process: Process?
    var failures = 0
    var retryAt = Date.distantPast
    // Exited 0: leave it be until the file changes.
    var done = false
    // When we asked it to stop; past the grace it is killed.
    var stopping: Date?
    var removed = false

    init(file: String, stamp: Date) {
        self.file = file
        self.stamp = stamp
    }
}

final class ScriptAutoload {
    private static let scanEvery: TimeInterval = 2
    private static let stopGrace: TimeInterval = 5
    private static let maxBackoff: TimeInterval = 60
    private static let logCap = 1 << 20
    private static let suffix = ".lua"

    private let dir: String
    private let logDir: String
    private let sock: String
    private let lock = NSLock()
    private var entries = [String: Entry]()
    private var lastScan = Date.distantPast

    // sock is the daemon the scripts belong to: what they are told to dial.
    init(sock: String, statePath: String) {
        self.sock = sock
        dir = PeerConfig.dir() + "/autoload"
        logDir = (statePath as NSString).deletingLastPathComponent + "/script-logs"
    }

    // From the daemon's housekeeping tick: cheap unless the folder is due.
    func poll() {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if now.timeIntervalSince(lastScan) >= Self.scanEvery {
            lastScan = now
            scan()
        }

        for e in Array(entries.values) {
            tend(e, now)
        }
    }

    func stopAll() {
        lock.lock()
        defer { lock.unlock() }

        for e in entries.values { e.process?.terminate() }

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, entries.values.contains(where: { $0.process?.isRunning == true }) {
            usleep(20_000)
        }
        for e in entries.values {
            guard let p = e.process, p.isRunning else { continue }

            kill(p.processIdentifier, SIGKILL)
        }
    }

    // MARK: Folder

    private func scan() {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(Self.suffix) && !$0.hasPrefix(".") }
        var seen = Set<String>()

        for name in names {
            let path = dir + "/" + name
            guard let stamp = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }

            seen.insert(name)
            guard let e = entries[name] else {
                entries[name] = Entry(file: path, stamp: stamp)
                continue
            }

            // Saved again: a fresh start, whatever happened to the last run.
            guard e.stamp != stamp else { continue }

            e.stamp = stamp
            e.done = false
            e.failures = 0
            e.retryAt = .distantPast
            stop(e)
        }

        for (name, e) in entries where !seen.contains(name) {
            e.removed = true
            stop(e)
        }
    }

    // MARK: One script

    private func stop(_ e: Entry) {
        guard let p = e.process, p.isRunning, e.stopping == nil else { return }

        e.stopping = Date()
        p.terminate()
    }

    private func tend(_ e: Entry, _ now: Date) {
        if let p = e.process, p.isRunning {
            if let since = e.stopping, now.timeIntervalSince(since) > Self.stopGrace {
                kill(p.processIdentifier, SIGKILL)
            }
            return
        }

        if let p = e.process {
            ended(e, status: p.terminationStatus, now: now)
        }

        if e.removed {
            entries[(e.file as NSString).lastPathComponent] = nil
            return
        }

        guard e.process == nil, !e.done, now >= e.retryAt else { return }

        launch(e, now)
    }

    private func ended(_ e: Entry, status: Int32, now: Date) {
        e.process = nil
        let asked = e.stopping != nil
        e.stopping = nil
        guard !asked else { return }

        guard status != 0 else {
            e.done = true
            return
        }

        e.failures += 1
        let wait = min(Self.maxBackoff, pow(2, Double(e.failures)))
        e.retryAt = now.addingTimeInterval(wait)
        log("autoload \((e.file as NSString).lastPathComponent) exited \(status); retry in \(Int(wait))s")
    }

    private func launch(_ e: Entry, _ now: Date) {
        let name = (e.file as NSString).lastPathComponent
        guard let exe = Bundle.main.executablePath ?? CommandLine.arguments.first else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--sock", sock, "lua", e.file]
        // Not a pane: no GCT_PANE_ID, so the script has no "self".
        var env = ProcessInfo.processInfo.environment
        env["GCT_PANE_ID"] = nil
        p.environment = env
        p.standardInput = FileHandle.nullDevice

        if let out = openLog(name) {
            p.standardOutput = out
            p.standardError = out
        }

        do {
            try p.run()
            e.process = p
            log("autoload \(name) started (pid \(p.processIdentifier))")
        } catch {
            e.failures += 1
            e.retryAt = now.addingTimeInterval(min(Self.maxBackoff, pow(2, Double(e.failures))))
            log("autoload \(name) won't start: \(error.localizedDescription)")
        }
    }

    // Appended to across runs, cut back once it passes a megabyte.
    private func openLog(_ name: String) -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        let path = "\(logDir)/\(name).log"
        let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        if size > Self.logCap { try? fm.removeItem(atPath: path) }
        if !fm.fileExists(atPath: path) { _ = fm.createFile(atPath: path, contents: nil) }

        guard let h = FileHandle(forWritingAtPath: path) else { return nil }

        h.seekToEndOfFile()
        h.write(Data("---- \(Date()) start\n".utf8))
        return h
    }
}
