// gct.exec: run a program for a script. No shell: argv goes straight to the
// kernel, so nothing needs quoting. Output is read on helper threads and handed
// to the loop through its mailbox, so a child's chatter is ordered with
// everything else the script sees and never runs script code on its own.
//
//   child ─pipe─► reader thread ─post─► loop thread ─► capture / stream callback
//   child ─exit─► termination handler ─post─► loop thread ─► settle

import Foundation

private let killGrace: TimeInterval = 2
private let signalNames: [String: Int32] = [
    "HUP": SIGHUP, "INT": SIGINT, "QUIT": SIGQUIT, "KILL": SIGKILL, "TERM": SIGTERM,
    "USR1": SIGUSR1, "USR2": SIGUSR2, "STOP": SIGSTOP, "CONT": SIGCONT, "PIPE": SIGPIPE,
    "ABRT": SIGABRT, "SEGV": SIGSEGV, "ALRM": SIGALRM,
]
// Result code when a signal, not an exit, ended the command.
private let signalledCode: Int32 = -1

enum ExecSink {
    case capture, discard, stream
}

enum ExecStream {
    case out, err
}

enum ExecStdin {
    case none, text(Data), open
}

struct ExecSpec {
    var argv: [String]
    var cwd: String?
    var env = [String: String?]()
    var clearEnv = false
    var stdin = ExecStdin.none
    var timeout: TimeInterval?
    var stdout = ExecSink.capture
    var stderr = ExecSink.capture
    var detach = false

    // From a script's options table. Callbacks come back beside the spec: the
    // Lua side owns them, and wires them to the job.
    static func parse(argv: Any?, opts: [String: Any]) throws -> (spec: ExecSpec, onOut: LuaFunc?, onErr: LuaFunc?) {
        guard let list = argv as? [Any], !list.isEmpty, let strs = list as? [String] else {
            throw ScriptError("exec wants a list of strings: program, then arguments")
        }

        var spec = ExecSpec(argv: strs)
        spec.cwd = opts["cwd"] as? String
        spec.clearEnv = opts["clear_env"] as? Bool ?? false
        spec.detach = opts["detach"] as? Bool ?? false
        spec.timeout = (opts["timeout"] as? Double) ?? (opts["timeout"] as? Int).map(Double.init)

        for (k, v) in opts["env"] as? [String: Any] ?? [:] {
            // .some(nil): a nil value would delete the key instead of recording the removal.
            spec.env[k] = .some(v as? String)
        }

        switch opts["stdin"] {
        case let s as String: spec.stdin = .text(Data(s.utf8))
        case let d as Data: spec.stdin = .text(d)
        case let keep as Bool where keep: spec.stdin = .open
        default: break
        }

        let outFn = opts["stdout"] as? LuaFunc
        let errFn = opts["stderr"] as? LuaFunc
        spec.stdout = sink(opts["stdout"], streams: outFn != nil)
        spec.stderr = sink(opts["stderr"], streams: errFn != nil)
        return (spec, outFn, errFn)
    }

    private static func sink(_ v: Any?, streams: Bool) -> ExecSink {
        if streams { return .stream }

        return v as? Bool == false ? .discard : .capture
    }
}

final class ExecJob {
    let id: Int
    let detach: Bool
    fileprivate let process = Process()
    fileprivate var stdinPipe: Pipe?
    fileprivate var openPipes = 0
    fileprivate var readers = [(pipe: Pipe, stream: ExecStream)]()
    fileprivate var terminated = false
    fileprivate var status: Int32 = 0
    fileprivate var bySignal = false
    private var out = Data()
    private var err = Data()
    private(set) var finished = false
    private(set) var timedOut = false
    fileprivate var sinks = (out: ExecSink.capture, err: ExecSink.capture)

    // Run on the loop thread, once per chunk, in the order chunks arrived.
    var onOut: ((Data) -> Void)?
    var onErr: ((Data) -> Void)?

    fileprivate init(id: Int, detach: Bool) {
        self.id = id
        self.detach = detach
    }

    var pid: Int32 { process.processIdentifier }
    var running: Bool { !finished && process.isRunning }

    fileprivate func chunk(_ d: Data, on stream: ExecStream, enqueue: (@escaping () -> Void) -> Void) {
        switch (stream == .err ? sinks.err : sinks.out) {
        case .capture:
            if stream == .err { err.append(d) } else { out.append(d) }
        case .stream:
            guard let cb = stream == .err ? onErr : onOut else { return }

            enqueue { cb(d) }
        case .discard:
            break
        }
    }

    fileprivate func markTimedOut() {
        timedOut = true
    }

    // Done once the process is gone AND both pipes have hit EOF: the last
    // chunk can trail the exit.
    fileprivate func settle() {
        guard terminated, openPipes == 0, !finished else { return }

        finished = true
    }

    func result() -> [String: Any] {
        var r: [String: Any] = [
            "code": bySignal ? Int(signalledCode) : Int(status),
            "stdout": String(decoding: out, as: UTF8.self),
            "stderr": String(decoding: err, as: UTF8.self),
            "timed_out": timedOut,
        ]
        r["ok"] = !bySignal && status == 0 && !timedOut
        if bySignal { r["signal"] = signalName(status) }
        return r
    }

    private func signalName(_ n: Int32) -> String {
        guard let hit = signalNames.first(where: { $0.value == n }) else { return String(n) }

        return "SIG" + hit.key
    }

    // "TERM", "SIGTERM" or 15.
    static func parseSignal(_ v: Any?) throws -> Int32 {
        switch v {
        case nil: return SIGTERM
        case let n as Int: return Int32(n)
        case let s as String:
            let name = s.uppercased().replacingOccurrences(of: "SIG", with: "")
            guard let n = signalNames[name] else { throw ScriptError("unknown signal \(s)") }

            return n
        default: throw ScriptError("signal is a name or a number")
        }
    }

    func signal(_ n: Int32) {
        guard running else { return }

        kill(pid, n)
    }

    func write(_ d: Data) throws {
        guard let h = stdinPipe?.fileHandleForWriting else { throw ScriptError("stdin is not open") }

        try h.write(contentsOf: d)
    }

    func closeStdin() {
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil
    }
}

final class ScriptExec {
    private let loop: ScriptLoop
    private var jobs = [Int: ExecJob]()
    private var nextID = 1

    init(loop: ScriptLoop) {
        self.loop = loop
    }

    // Wait for it; the result, or throws when it never started.
    func run(_ spec: ExecSpec) throws -> [String: Any] {
        let job = try launch(spec)
        let end = loop.pump(dispatch: .forbid) { job.finished }

        guard end == .done else {
            job.signal(SIGKILL)
            throw ScriptError("daemon went away")
        }

        jobs[job.id] = nil
        return job.result()
    }

    func start(_ spec: ExecSpec, onOut: LuaFunc?, onErr: LuaFunc?, deliver: @escaping (LuaFunc, Data) -> Void) throws -> ExecJob {
        let job = try launch(spec)
        if let onOut { job.onOut = { deliver(onOut, $0) } }
        if let onErr { job.onErr = { deliver(onErr, $0) } }
        return job
    }

    // Everything not detached dies with the script.
    func killAll() {
        for job in jobs.values where !job.detach {
            job.signal(SIGTERM)
        }
    }

    func job(_ id: Int) -> ExecJob? {
        jobs[id]
    }

    private func launch(_ spec: ExecSpec) throws -> ExecJob {
        let job = ExecJob(id: nextID, detach: spec.detach)
        nextID += 1
        job.sinks = (spec.stdout, spec.stderr)

        let p = job.process
        let env = environment(spec)
        guard let exe = resolve(spec.argv[0], path: env["PATH"]) else {
            throw ScriptError("cannot run \(spec.argv[0]): not found")
        }

        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(spec.argv.dropFirst())
        p.environment = env
        if let cwd = spec.cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        wire(job, spec)
        do {
            try p.run()
        } catch {
            throw ScriptError("cannot run \(spec.argv[0]): \(error.localizedDescription)")
        }

        jobs[job.id] = job
        readers(job)
        feed(job, spec)
        limit(job, spec)
        return job
    }

    private func environment(_ spec: ExecSpec) -> [String: String] {
        var env = spec.clearEnv ? [:] : ProcessInfo.processInfo.environment
        for (k, v) in spec.env {
            env[k] = v
        }

        return env
    }

    // No shell, so no PATH lookup either: do it by hand.
    private func resolve(_ prog: String, path: String?) -> String? {
        let fm = FileManager.default
        if prog.contains("/") { return fm.isExecutableFile(atPath: prog) ? prog : nil }

        for dir in (path ?? "/usr/bin:/bin").split(separator: ":") {
            let candidate = "\(dir)/\(prog)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }

        return nil
    }

    // Pipes in, reader threads out. Every closure that touches the job runs
    // as a post, on the loop thread.
    private func wire(_ job: ExecJob, _ spec: ExecSpec) {
        let loop = self.loop
        let p = job.process

        switch spec.stdin {
        case .none:
            p.standardInput = FileHandle.nullDevice
        case .text, .open:
            job.stdinPipe = Pipe()
            p.standardInput = job.stdinPipe
        }

        p.standardOutput = reader(job, spec.stdout, stream: .out)
        p.standardError = reader(job, spec.stderr, stream: .err)

        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            let signalled = proc.terminationReason == .uncaughtSignal
            loop.post(.post {
                job.status = code
                job.bySignal = signalled
                job.terminated = true
                job.settle()
            })
        }
    }

    private func reader(_ job: ExecJob, _ sink: ExecSink, stream: ExecStream) -> Any {
        guard sink != .discard else { return FileHandle.nullDevice }

        let pipe = Pipe()
        job.openPipes += 1
        job.readers.append((pipe, stream))
        return pipe
    }

    // One blocking reader thread per pipe, started once the child runs. Not
    // readabilityHandler: its dispatch source never fires in the static Linux
    // build, and a plain read(2) loop behaves the same everywhere.
    private func readers(_ job: ExecJob) {
        let loop = self.loop

        for (pipe, stream) in job.readers {
            let h = pipe.fileHandleForReading

            Thread.detachNewThread {
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }

                    loop.post(.post { job.chunk(d, on: stream, enqueue: loop.enqueue) })
                }

                loop.post(.post {
                    job.openPipes -= 1
                    job.settle()
                })
            }
        }
        job.readers = []
    }

    private func feed(_ job: ExecJob, _ spec: ExecSpec) {
        guard case .text(let data) = spec.stdin, let h = job.stdinPipe?.fileHandleForWriting else { return }

        // A big payload can outlast the pipe buffer: don't stall the loop.
        DispatchQueue.global().async {
            try? h.write(contentsOf: data)
            try? h.close()
        }
        job.stdinPipe = nil
    }

    // SIGTERM at the limit, SIGKILL once the grace is up.
    private func limit(_ job: ExecJob, _ spec: ExecSpec) {
        guard let limit = spec.timeout else { return }

        let loop = self.loop
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
            loop.post(.post {
                guard !job.finished else { return }

                job.markTimedOut()
                job.signal(SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                    loop.post(.post { job.signal(SIGKILL) })
                }
            })
        }
    }
}
