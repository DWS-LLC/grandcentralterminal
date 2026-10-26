// gctd — headless daemon owning pane PTYs.
//
// With no subcommand it serves (single instance via pid file). With one it
// acts as a control CLI against the running daemon over the unix socket —
// this is the agent/harness surface: open a pane next to the working one,
// send it keys, read its scrollback, group it, close it. GCT_SOCK selects
// the daemon (panes inherit it, so in-pane `gctd` calls just work);
// --sock overrides it explicitly. --tcp=host:port + --token=.. target a
// remote daemon over TCP instead.
//
// Cross-platform: serves on macOS (unix socket, .app-bundled) and Linux
// (unix socket + optional TCP). Paths honor $HOME first (agentHome-style:
// NSHomeDirectory ignores $HOME), GCT_HOME overrides the base dir
// outright; on Linux the base is ~/.config/gct (XDG-style), on macOS the
// Application Support dir.

import Foundation
import Common

func log(_ s: String) {
    FileHandle.standardError.write(Data("[gctd] \(s)\n".utf8))
}

func die(_ s: String) -> Never {
    FileHandle.standardError.write(Data("gctd: \(s)\n".utf8))
    exit(1)
}

// Portable home: $HOME first (agents/sandboxes override it), passwd
// fallback. NSHomeDirectory() ignores $HOME.
func daemonHome() -> String {
    if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return h }
    return NSHomeDirectory()
}

// Base dir for daemon state: GCT_HOME wins outright; else platform
// default (macOS Application Support, Linux ~/.config/gct).
func daemonBaseDir() -> String {
    if let b = ProcessInfo.processInfo.environment["GCT_HOME"], !b.isEmpty { return b }
    let home = daemonHome()
#if os(Linux)
    return home + "/.config/gct"
#else
    return (home as NSString)
        .appendingPathComponent("Library/Application Support/Grand Central Terminal")
#endif
}

let supportDir = daemonBaseDir()
// Test/bench isolation: point a daemon at scratch paths without touching the
// live instance. Unset (normal use) = current defaults.
let env = ProcessInfo.processInfo.environment
var sockPath = env["GCT_SOCK"] ?? supportDir + "/daemon.sock"
let statePath = env["GCT_STATE"] ?? supportDir + "/state.json"
let pidPath = env["GCT_PID"] ?? supportDir + "/daemon.pid"
// TCP serve: --port=N (or GCT_PORT) opens a TCP listener alongside the
// unix socket; --token=.. (or GCT_TOKEN) gates it (empty = open).
var tcpPort: UInt16? {
    if let p = env["GCT_PORT"], let n = UInt16(p), n > 0 { return n }
    return nil
}
var tcpToken: String {
    env["GCT_TOKEN"] ?? ""
}
// TCP client target: --tcp=host:port (or GCT_TCP) routes CLI subcommands
// over TCP instead of the unix socket; --token=.. (or GCT_TOKEN) auths.
var tcpTarget: String? {
    env["GCT_TCP"]
}

var args = Array(CommandLine.arguments.dropFirst())
// Early flags applying to every subcommand (serve + CLI):
// --sock=<p>|--sock <p>, --tcp=<host:port>|--tcp <host:port>,
// --token=<t>|--token <t>, --port=<n>|--port <n>.
var cliToken: String?
var cliTCPTarget: String? = tcpTarget
var servePort: UInt16? = tcpPort
var serveToken: String = tcpToken
var i = 0
while i < args.count {
    if args[i] == "--sock", i + 1 < args.count {
        sockPath = args[i + 1]
        args.remove(at: i + 1); args.remove(at: i)
    } else if args[i].hasPrefix("--sock=") {
        sockPath = String(args[i].dropFirst("--sock=".count))
        args.remove(at: i)
    } else if args[i] == "--tcp", i + 1 < args.count {
        cliTCPTarget = args[i + 1]
        args.remove(at: i + 1); args.remove(at: i)
    } else if args[i].hasPrefix("--tcp=") {
        cliTCPTarget = String(args[i].dropFirst("--tcp=".count))
        args.remove(at: i)
    } else if args[i] == "--token", i + 1 < args.count {
        cliToken = args[i + 1]
        args.remove(at: i + 1); args.remove(at: i)
    } else if args[i].hasPrefix("--token=") {
        cliToken = String(args[i].dropFirst("--token=".count))
        args.remove(at: i)
    } else if args[i] == "--port", i + 1 < args.count {
        servePort = UInt16(args[i + 1])
        args.remove(at: i + 1); args.remove(at: i)
    } else if args[i].hasPrefix("--port=") {
        servePort = UInt16(String(args[i].dropFirst("--port=".count)))
        args.remove(at: i)
    } else {
        i += 1
    }
}
// Serve reads its token from --token/GCT_TOKEN; CLI sends it (flag wins).
if cliTCPTarget == nil, let t = cliToken { serveToken = t }
let cliAuthToken: String? = cliToken ?? (env["GCT_TOKEN"]?.isEmpty == false ? env["GCT_TOKEN"] : nil)

// MARK: - CLI client

// One-shot connection: greet (drains the server's eager welcome), run,
// drain the tagged reply, close. The daemon's serve() always emits a
// welcome on connect, then answers each request — so every command reads
// exactly: welcome, answer. Routes over TCP (--tcp/GCT_TCP) with the auth
// token (--token/GCT_TOKEN), else the local unix socket.
final class GCTClient {
    let conn: Conn
    init?() {
        if let target = cliTCPTarget, let (host, port) = parseTCP(target) {
            let fd = connectTCP(host: host, port: port)
            guard fd >= 0 else { return nil }
            conn = Conn(fd: fd)
            // Auth first: wrong/missing token gets errorReply, no welcome.
            _ = conn.send(tag: .hello, json: Hello(token: cliAuthToken))
        } else if cliTCPTarget != nil {
            return nil // malformed --tcp target
        } else {
            let fd = connectUnixSocket(sockPath)
            guard fd >= 0 else { return nil }
            conn = Conn(fd: fd)
        }
        _ = conn.readFrame() // eager welcome (or errorReply on bad token)
    }
    // Next reply frame. Broadcast state updates (paneMeta/groupMeta/...)
    // may arrive first on a busy daemon — skip those; the tagged replies
    // (welcome, paneCreated, paneDump, groupCreated, errorReply) pass
    // through. Never skip welcome/paneList: listPanes ANSWERS with them.
    func nextReply() -> Frame? {
        while let f = conn.readFrame() {
            switch f.tag {
            case .paneMeta, .groupMeta, .groupExit, .paneExit:
                continue
            default:
                return f
            }
        }
        return nil
    }
    func welcome() -> Welcome? {
        _ = conn.send(tag: .listPanes, json: Hello(version: ProtoVersion, token: cliAuthToken))
        guard let f = nextReply(), f.tag == .welcome || f.tag == .paneList,
              let w: Welcome = f.decode() else { return nil }
        return w
    }
}

// "host:port" (port optional, default GCTDefaultPort). Bracketed IPv6
// ("[::1]:7420") and bare hostnames work.
func parseTCP(_ s: String) -> (String, UInt16)? {
    var host = s, port = GCTDefaultPort
    if s.hasPrefix("["), let end = s.firstIndex(of: "]") {
        host = String(s[s.index(after: s.startIndex)..<end])
        let rest = s[s.index(after: end)...]
        if rest.hasPrefix(":"), let n = UInt16(rest.dropFirst()) { port = n }
        else if !rest.isEmpty { return nil }
    } else if let colon = s.lastIndex(of: ":"), s[s.index(after: colon)...].allSatisfy(\.isNumber),
              let n = UInt16(s[s.index(after: colon)...]) {
        host = String(s[..<colon]); port = n
    }
    guard !host.isEmpty else { return nil }
    return (host, port)
}

let sendUsage = "send <pane> [text]... [--no-newline] [--paste]  (no text: read stdin)"
let notifyUsage = "notify <pane> [title=..] <text>...  |  notify <pane> --hook"
let bracketedPasteStart = "\u{1B}[200~"
let bracketedPasteEnd = "\u{1B}[201~"

// \xHH (any byte: \x03 is ^C), \e, \n, \t, \r, \\ -> the bytes they
// name. Anything else keeps its backslash.
func unescapeKeys(_ s: String) -> String {
    let chars = Array(s.unicodeScalars)
    var out = String.UnicodeScalarView()
    var i = 0

    while i < chars.count {
        let c = chars[i]
        guard c == "\\", i + 1 < chars.count else { out.append(c); i += 1; continue }

        let e = chars[i + 1]
        if e == "x", i + 3 < chars.count, let byte = hexByte(chars[i + 2], chars[i + 3]) {
            out.append(Unicode.Scalar(byte))
            i += 4
            continue
        }

        switch e {
        case "n": out.append("\n")
        case "t": out.append("\t")
        case "r": out.append("\r")
        case "e": out.append("\u{1B}")
        case "\\": out.append("\\")
        default: out.append(c); out.append(e)
        }
        i += 2
    }
    return String(out)
}

func hexByte(_ hi: Unicode.Scalar, _ lo: Unicode.Scalar) -> UInt8? {
    UInt8(String(hi) + String(lo), radix: 16)
}

// Claude Code hook payload -> notification text. Notification hooks carry
// the message; Stop means the turn finished. Nil = nothing to say.
func hookNotice(_ raw: Data) -> (title: String, body: String)? {
    let title = "Claude Code"
    guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }

    if let message = obj["message"] as? String, !message.isEmpty { return (title, message) }
    if obj["hook_event_name"] as? String == "Stop" { return (title, "Finished, waiting for you") }
    return nil
}

// Resolve a pane by uuid prefix, exact name, or $GCT_PANE_ID shorthand.
// "self" = this pane (requires GCT_PANE_ID in env, i.e. called from a pane).
func resolvePane(_ w: Welcome, _ raw: String) -> PaneMeta? {
    let q: String
    if raw == "self" {
        guard let id = env["GCT_PANE_ID"], !id.isEmpty else {
            die("self needs GCT_PANE_ID (run from inside a GCT pane)")
        }
        q = id
    } else {
        q = raw
    }
    if let hit = w.panes.first(where: { $0.id.uuid.uuidString == q }) { return hit }
    if let hit = w.panes.first(where: {
        $0.id.uuid.uuidString.lowercased().hasPrefix(q.lowercased())
    }) { return hit }
    let named = w.panes.filter { ($0.name ?? "Terminal") == q }
    if named.count == 1 { return named[0] }
    if named.count > 1 { die("name \(q) matches \(named.count) panes; use an id prefix") }
    return nil
}

func resolveGroup(_ w: Welcome, _ raw: String) -> GroupMeta? {
    if let hit = w.groups.first(where: { $0.id.uuid.uuidString == raw }) { return hit }
    if let hit = w.groups.first(where: {
        $0.id.uuid.uuidString.lowercased().hasPrefix(raw.lowercased())
    }) { return hit }
    let named = w.groups.filter { ($0.name ?? "") == raw }
    if named.count == 1 { return named[0] }
    if named.count > 1 { die("name \(raw) matches \(named.count) groups; use an id prefix") }
    return nil
}

// `key=value` args after the subcommand.
func flags(_ args: [String]) -> [String: String] {
    var out = [String: String]()
    for a in args {
        guard let eq = a.firstIndex(of: "=") else { die("expected key=value, got \(a)") }
        out[String(a[..<eq])] = String(a[a.index(after: eq)...])
    }
    return out
}

// "x,y,w,h" in world points, e.g. "0,0,900,560".
func parseRect(_ raw: String) -> Rect {
    let n = raw.split(separator: ",").compactMap { Double($0) }
    guard n.count == 4 else { die("rect must be x,y,w,h, got \(raw)") }
    return Rect(x: n[0], y: n[1], w: n[2], h: n[3])
}

// Optional numeric flag; present-but-garbage dies instead of guessing.
func number(_ f: [String: String], _ key: String) -> Double? {
    guard let raw = f[key] else { return nil }
    guard let n = Double(raw) else { die("\(key) must be a number, got \(raw)") }
    return n
}

// Relay a scripted canvas command; like focus, the broadcast IS the
// delivery, so only an errorReply (bad pane) is surfaced.
func sendCanvas(_ c: GCTClient, _ cmd: CanvasCommand) -> Never {
    _ = c.conn.send(tag: .canvasCommand, json: cmd)
    if let r = c.nextReply(), r.tag == .errorReply,
       let e: ErrorReply = r.decode() { die(e.message) }
    exit(0)
}

// MARK: - ANSI scrubber (for `dump --strip-ansi`)

func stripANSI(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    var j = s.startIndex
    let end = s.endIndex
    while j < end {
        let c = s[j]
        if c == "\u{1B}" {
            let k = s.index(after: j)
            if k < end && s[k] == "[" {
                // CSI: consume through the final byte (@-~).
                var m = s.index(after: k)
                while m < end {
                    let d = s[m]
                    if d >= "@" && d <= "~" {
                        j = s.index(after: m)
                        break
                    }
                    m = s.index(after: m)
                }
                if m >= end { j = end }
                continue
            }
            if k < end && (s[k] == "]" || s[k] == "P" || s[k] == "X" || s[k] == "^" || s[k] == "_") {
                // OSC/APC/DCS/...: consume through ESC \ or BEL.
                var m = s.index(after: k)
                while m < end {
                    if s[m] == "\u{07}" { m = s.index(after: m); break }
                    if s[m] == "\u{1B}" {
                        let n = s.index(after: m)
                        if n < end && s[n] == "\\" { m = s.index(after: n); break }
                    }
                    m = s.index(after: m)
                }
                j = m
                continue
            }
            // Lone ESC + one char (charset selects etc.): drop both.
            j = k < end ? s.index(after: k) : end
            continue
        }
        if c == "\u{07}" || c == "\u{08}" { j = s.index(after: j); continue } // BEL/BS
        out.append(c)
        j = s.index(after: j)
    }
    return out
}

func usage() -> Never {
    fputs("""
        usage: gctd <command> [args]

          Daemon control (no command runs the daemon itself):
            status                    list panes (alias: list)
            stop                      kill daemon + panes
            version                   print the gctd version (--version)

          Agent/harness surface (prefer GCT panes for background tasks:
          grouped, no time limits, user-inspectable on the canvas):
            open [cwd=..] [name=..] [cmd=..] [group=..] [parent=<pane>] [size=w,h] [rect=x,y,w,h]
                                      open a pane beside focused/origin, print its id
                                      (parent= wires it to that pane, whoever calls)
            tie <parent> <child>... [at=0.4]
                                      tie the cables from <parent> to each <child>
                                      into one bundle; prints the tie id
            untie <tie>               remove a tie
            move <pane> rect=x,y,w,h  place a pane (overlap rules still apply)
            list                      panes + groups, one per line
            dump <pane> [limit=N] [--strip-ansi]
                                      scrollback snapshot (id prefix, name, or self)
            send <pane> [text]...     type text into a pane (appends newline;
                                      --no-newline to skip; --paste brackets it;
                                      \\xHH/\\e/\\n/\\t escapes; no text reads stdin)
            notify <pane> [title=..] <text>...
                                      desktop notification, click focuses the pane
                                      (--hook: Claude Code hook payload on stdin)
            close <pane>              terminate a pane
            rename <pane> name=..     name a pane
            group <pane>... name=.. [color=#..]
                                      group panes (2+), print group id
            ungroup <group>           dissolve a group (panes survive)
            focus <pane>              focus + center a pane on the canvas
            camera [pane] [x=.. y=..] [zoom=..] [dur=..]
                                      glide the camera to a world point or pane
            do <action> [pane] [dur=..]
                                      run a keybind action (fit-all, zoom-pane..)
            agent-setup print|install|uninstall|context
                                      skill install + live pane context for hooks
                                      (--harness=claude,codex,opencode,cursor,cursor-agents;
                                      install --hooks merges a Claude SessionStart hook)
        """, stderr)
    exit(2)
}

guard let verb = args.first else {
    // No subcommand: serve the daemon (single instance via pid file).
    if let data = FileManager.default.contents(atPath: pidPath),
       let old = Int(String(decoding: data, as: UTF8.self)
           .trimmingCharacters(in: .whitespacesAndNewlines)),
       old != ProcessInfo.processInfo.processIdentifier,
       kill(pid_t(old), 0) == 0 {
        log("another daemon (pid \(old)) already running")
        exit(0)
    }
    try? Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
        .write(to: URL(fileURLWithPath: pidPath), options: .atomic)

    // One-time migration from the pre-rename support dir, so an existing pane
    // layout survives the move to Application Support/Grand Central Terminal.
    let fm = FileManager.default
    let legacyDir = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/tmuxInfiniteCanvas")
    // Isolated instances (GCT_STATE set) never inherit the legacy layout.
    if env["GCT_STATE"] == nil, !fm.fileExists(atPath: statePath),
       fm.fileExists(atPath: legacyDir + "/state.json") {
        try? fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        try? fm.copyItem(atPath: legacyDir + "/state.json", toPath: statePath)
        log("migrated pane state from \(legacyDir)")
    }

    let state = StateStore(path: statePath)
    let server = Server(state: state, sockPath: sockPath,
                        tcpPort: servePort, token: serveToken)

    signal(SIGPIPE, SIG_IGN)
    // On TERM/INT: children get EIO on their pty master once we die and exit.
    signal(SIGTERM) { _ in exit(0) }
    signal(SIGINT) { _ in exit(0) }

    server.run()
    fatalError("unreachable")
}

let rest = Array(args.dropFirst())
// Where along the cable `gctd tie` puts a tie unless told (0...1).
let defaultTieAt = 0.4

func needClient() -> GCTClient {
    guard let c = GCTClient() else { die("daemon not running (\(sockPath))") }
    return c
}

switch verb {
case "version", "--version":
    print("gctd \(GCTVersion) (proto \(ProtoVersion))")
    exit(0)

case "status", "list":
    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    if w.panes.isEmpty { print("no panes") }
    let auto = AutoName.names(w.panes.map {
        AutoName.Pane(id: $0.id, cwd: $0.cwd, proc: $0.proc, title: $0.title,
                      repoRoot: $0.repoRoot, worktree: $0.worktree)
    }, home: daemonHome())
    for p in w.panes {
        let name = p.name ?? auto[p.id] ?? "Terminal"
        print("\(p.id)  \(name)  \(p.cwd)  exited=\(p.exited)")
    }
    for g in w.groups {
        print("group \(g.id)  \(g.name ?? "")  members=\(g.members.count)")
    }
    let names = Dictionary(uniqueKeysWithValues: w.panes.map { ($0.id, $0.name ?? auto[$0.id] ?? "Terminal") })
    for t in w.ties {
        let cables = t.strands.map { "\(names[$0.parent] ?? "?")>\(names[$0.child] ?? "?")" }
        print("tie \(t.id)  at=\(String(format: "%.2f", t.s))  \(cables.joined(separator: " "))")
    }
    exit(0)

case "stop":
    let c = needClient()
    _ = c.conn.send(tag: .killDaemon, json: Hello(version: ProtoVersion))
    exit(0)

case "open":
    // Placement: daemon resolves against live layout (overlap-free stream),
    // so ask for origin-adjacent and let arbitration land it. Prefer beside
    // the calling pane (self) when resolvable, else canvas origin.
    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    let f = flags(rest)
    var anchor = Rect(x: 0, y: 0, w: 900, h: 560)
    var join: GroupID?
    var orbit: PaneID?
    var caller = env["GCT_PANE_ID"].flatMap { selfID in
        w.panes.first(where: { $0.id.uuid.uuidString == selfID })
    }
    // parent= stands in for the caller: placed beside it, wired to it.
    var parent: PaneID?
    if let pq = f["parent"] {
        guard let p = resolvePane(w, pq) else { die("no such pane \(pq)") }
        caller = p
        parent = p.id
    }
    if let me = caller {
        anchor = Rect(x: me.rect.x + me.rect.w, y: me.rect.y,
                      w: me.rect.w, h: me.rect.h)
        join = w.groups.first(where: { $0.members.contains(me.id) })?.id
        orbit = me.id
    }
    // Explicit group= name/id joins that group instead (daemon admits).
    if let gq = f["group"], let g = resolveGroup(w, gq) {
        join = g.id
        orbit = nil
    }
    // size=w,h keeps the beside-caller spot, resized to fit the job.
    if let s = f["size"] {
        let n = s.split(separator: ",").compactMap { Double($0) }
        guard n.count == 2 else { die("size must be w,h, got \(s)") }
        anchor.w = n[0]
        anchor.h = n[1]
    }
    // Explicit rect=x,y,w,h (world points) pins the spot; still resolved.
    if let r = f["rect"] { anchor = parseRect(r) }
    // No cwd= opens where the caller stands (agents expect `cd repo; gctd
    // open cmd=make` to build the repo, not $HOME).
    let cwd = f["cwd"] ?? FileManager.default.currentDirectoryPath
    _ = c.conn.send(tag: .createPane, json: CreatePane(
        rect: anchor, cwd: cwd, name: f["name"], command: f["cmd"],
        joinGroup: join, joinDirection: join == nil ? nil : "right",
        orbitAround: f["rect"] == nil ? orbit : nil, parent: parent))
    // Answer is a paneCreated broadcast; errorReply on spawn failure.
    // Tag-check first: a stray broadcast decodes as nothing, not as the
    // wrong reply (all reply shapes are [$id] flat strings otherwise).
    while let r = c.nextReply() {
        if r.tag == .paneCreated, let m: PaneCreated = r.decode() { print(m.meta.id); exit(0) }
        if r.tag == .errorReply, let e: ErrorReply = r.decode() { die(e.message) }
    }
    die("no reply from daemon")

case "dump":
    guard !rest.isEmpty else { die("dump <pane> [limit=N] [--strip-ansi]") }
    var strip = false
    var limit = 0
    var target: String?
    for a in rest {
        if a == "--strip-ansi" || a == "--strip" { strip = true }
        else if a.hasPrefix("limit=") { guard let n = Int(a.dropFirst(6)) else { die("bad limit") }; limit = n }
        else if target == nil { target = a }
        else { die("unexpected \(a)") }
    }
    guard let tq = target else { die("dump <pane> [limit=N] [--strip-ansi]") }
    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    guard let pane = resolvePane(w, tq) else { die("no such pane \(tq)") }
    _ = c.conn.send(tag: .dumpPane, json: DumpPane(id: pane.id, limit: limit))
    while let r = c.nextReply() {
        if r.tag == .paneDump, let d: PaneDump = r.decode() {
            var text: String
            if d.base64, let raw = Data(base64Encoded: d.data) {
                text = String(data: raw, encoding: .utf8) ?? "<binary>"
            } else {
                text = d.data
            }
            if strip { text = stripANSI(text) }
            fputs(text, stdout)
            if !text.hasSuffix("\n") { fputs("\n", stdout) }
            if d.truncated {
                fputs("[truncated: showing last \(d.bytes) bytes, ring dropped \(d.dropped)]\n", stderr)
            }
            exit(0)
        }
        if r.tag == .errorReply, let e: ErrorReply = r.decode() { die(e.message) }
    }
    die("no reply from daemon")

case "send":
    // send <pane> [text]... — keys, not a shell command: the bytes land
    // in the pane's stdin exactly as typed (+ trailing newline default).
    // No text args reads stdin, so output pipes between panes:
    //   gctd dump build --strip-ansi | gctd send agent --paste
    guard rest.count >= 1 else { die(sendUsage) }
    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    guard let pane = resolvePane(w, rest[0]) else { die("no such pane \(rest[0])") }
    var parts = Array(rest.dropFirst())
    var newline = true
    var paste = false
    parts.removeAll {
        if $0 == "--no-newline" { newline = false; return true }
        if $0 == "--paste" { paste = true; return true }
        return false
    }

    var text: String
    if parts.isEmpty {
        guard isatty(STDIN_FILENO) == 0 else { die(sendUsage) }
        text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        // The piped payload is literal; its last newline is just EOF.
        if text.hasSuffix("\n") { text.removeLast() }
    } else {
        text = unescapeKeys(parts.joined(separator: " "))
    }
    guard !text.isEmpty else { die(sendUsage) }

    // Bracketed paste: a multi-line payload lands as one paste instead of
    // running line by line. The app must have asked for it (DECSET 2004).
    if paste { text = bracketedPasteStart + text + bracketedPasteEnd }
    if newline { text += "\n" }
    _ = c.conn.sendData(tag: .inputPane, paneID: pane.id, data: Data(text.utf8))
    exit(0)

case "notify":
    // notify <pane> [title=..] <text>... | --hook
    // Desktop notification that focuses the pane when clicked. --hook
    // reads a Claude Code hook payload on stdin and never fails: a hook
    // must not block the agent.
    let isHook = rest.contains("--hook")
    let words = rest.filter { $0 != "--hook" }
    guard let target = words.first else { die(notifyUsage) }

    var title: String?
    var body = words.dropFirst().filter { !$0.hasPrefix("title=") }.joined(separator: " ")
    if let t = words.first(where: { $0.hasPrefix("title=") }) { title = String(t.dropFirst("title=".count)) }

    if isHook {
        if target == "self", env["GCT_PANE_ID"] == nil { exit(0) }
        let hook = hookNotice(FileHandle.standardInput.readDataToEndOfFile())
        guard let hook else { exit(0) }
        title = title ?? hook.title
        body = hook.body
    }
    guard !body.isEmpty else { die(notifyUsage) }

    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    guard let pane = resolvePane(w, target) else { die("no such pane \(target)") }
    _ = c.conn.send(tag: .notifyPane, json: PaneNotify(id: pane.id, title: title, body: body))
    exit(0)

case "close":
    guard rest.count == 1 else { die("close <pane>") }
    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    guard let pane = resolvePane(w, rest[0]) else { die("no such pane \(rest[0])") }
    _ = c.conn.send(tag: .closePane, json: PaneRef(id: pane.id))
    exit(0)

case "tie":
    let args = rest.filter { !$0.contains("=") }
    guard args.count >= 3 else { die("tie <parent> <child> <child>... [at=0.4]") }
    let f = flags(rest.filter { $0.contains("=") })
    let at = f["at"].flatMap(Double.init) ?? defaultTieAt
    guard (0...1).contains(at) else { die("at must be 0...1, got \(f["at"] ?? "")") }

    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    guard let parent = resolvePane(w, args[0]) else { die("no such pane \(args[0])") }
    let strands = args.dropFirst().map { q -> TieMeta.Strand in
        guard let child = resolvePane(w, q) else { die("no such pane \(q)") }
        guard child.parent == parent.id else { die("\(q) was not spawned by \(args[0]): no cable to tie") }
        return TieMeta.Strand(parent: parent.id, child: child.id)
    }

    let tie = TieMeta(s: at, strands: strands)
    _ = c.conn.send(tag: .setTie, json: tie)
    while let r = c.nextReply() {
        if r.tag == .tieMeta, let m: TieMeta = r.decode(), m.id == tie.id { print(m.id); exit(0) }
        if r.tag == .errorReply, let e: ErrorReply = r.decode() { die(e.message) }
    }
    die("no reply from daemon")

case "untie":
    guard rest.count == 1 else { die("untie <tie>") }
    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    let matches = w.ties.filter { $0.id.hasPrefix(rest[0].uppercased()) || $0.id == rest[0] }
    guard matches.count == 1 else { die(matches.isEmpty ? "no such tie \(rest[0])" : "ambiguous tie \(rest[0])") }
    _ = c.conn.send(tag: .removeTie, json: TieRef(id: matches[0].id))
    exit(0)

case "rename":
    guard rest.count == 2, rest[1].hasPrefix("name=") else { die("rename <pane> name=..") }
    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    guard let pane = resolvePane(w, rest[0]) else { die("no such pane \(rest[0])") }
    let name = String(rest[1].dropFirst(5))
    _ = c.conn.send(tag: .renamePane, json: RenamePane(id: pane.id, name: name.isEmpty ? nil : name))
    exit(0)

case "group":
    guard rest.count >= 2 else { die("group <pane>... name=.. [color=#..]") }
    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    var name: String?
    var color: String?
    var panes = [PaneID]()
    for a in rest {
        if a.hasPrefix("name=") { name = String(a.dropFirst(5)) }
        else if a.hasPrefix("color=") { color = String(a.dropFirst(6)) }
        else if let p = resolvePane(w, a) { panes.append(p.id) }
        else { die("no such pane \(a)") }
    }
    guard panes.count >= 2 else { die("group needs 2+ panes") }
    _ = c.conn.send(tag: .createGroup, json: CreateGroup(name: name, color: color, members: panes))
    while let r = c.nextReply() {
        if r.tag == .groupCreated, let m: GroupCreated = r.decode() { print(m.meta.id); exit(0) }
        if r.tag == .errorReply, let e: ErrorReply = r.decode() { die(e.message) }
    }
    die("no reply from daemon")

case "ungroup":
    guard rest.count == 1 else { die("ungroup <group>") }
    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    guard let g = resolveGroup(w, rest[0]) else { die("no such group \(rest[0])") }
    _ = c.conn.send(tag: .deleteGroup, json: GroupRef(id: g.id))
    exit(0)

case "focus":
    guard rest.count == 1 else { die("focus <pane>") }
    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    guard let pane = resolvePane(w, rest[0]) else { die("no such pane \(rest[0])") }
    // Daemon validates + broadcasts paneFocus; the canvas focuses,
    // raises, and centers per its camera-follows/fits flags. No success
    // reply — the broadcast IS the delivery (canvas may be hidden).
    // Drain one frame so a bad id surfaces errorReply instead of
    // silently succeeding.
    _ = c.conn.send(tag: .focusPane, json: PaneRef(id: pane.id))
    if let r = c.nextReply(), r.tag == .errorReply,
       let e: ErrorReply = r.decode() { die(e.message) }
    exit(0)

case "move":
    // gctd move <pane> rect=x,y,w,h: place a pane (daemon-resolved, so
    // the no-overlap policy still holds). Scene staging for demos.
    guard rest.count == 2, rest[1].hasPrefix("rect=") else { die("move <pane> rect=x,y,w,h") }
    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    guard let pane = resolvePane(w, rest[0]) else { die("no such pane \(rest[0])") }
    let rect = parseRect(String(rest[1].dropFirst("rect=".count)))
    _ = c.conn.send(tag: .movePane, json: MovePane(id: pane.id, rect: rect))
    exit(0)

case "camera":
    // gctd camera [pane] [x=.. y=..] [zoom=..] [dur=..]
    // e.g. `gctd camera build zoom=0.4 dur=3` glides to build's center.
    let positional = rest.filter { !$0.contains("=") }
    guard positional.count <= 1 else { die("camera [pane] [x=..] [y=..] [zoom=..] [dur=..]") }
    let f = flags(rest.filter { $0.contains("=") })
    let c = needClient()
    var cmd = CanvasCommand(verb: .camera,
                            x: number(f, "x"), y: number(f, "y"),
                            zoom: number(f, "zoom"), duration: number(f, "dur"))
    if let raw = positional.first {
        guard let w = c.welcome() else { die("no reply from daemon") }
        guard let pane = resolvePane(w, raw) else { die("no such pane \(raw)") }
        cmd.pane = pane.id
    }
    sendCanvas(c, cmd)

case "do":
    // gctd do <action> [pane] [dur=..]: run a keybind action (config name, e.g.
    // fit-all, zoom-pane, open-new-window-right), focusing pane first.
    // dur= paces the action's camera move, e.g. `do fit-all dur=4`.
    let positional = rest.filter { !$0.contains("=") }
    guard (1...2).contains(positional.count) else { die("do <action> [pane] [dur=..]") }
    let f = flags(rest.filter { $0.contains("=") })
    let c = needClient()
    var cmd = CanvasCommand(verb: .action, action: positional[0],
                            duration: number(f, "dur"))
    if positional.count == 2 {
        guard let w = c.welcome() else { die("no reply from daemon") }
        guard let pane = resolvePane(w, positional[1]) else { die("no such pane \(positional[1])") }
        cmd.pane = pane.id
    }
    sendCanvas(c, cmd)

default:
    // runAgentSetup exits on every path, but the compiler can't see
    // that (it returns void); belt-and-braces so usage never follows.
    if verb == "agent-setup" { runAgentSetup(rest); exit(0) }
    usage()
}
