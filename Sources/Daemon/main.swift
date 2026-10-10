// gctd — headless daemon owning pane PTYs.
//
// With no subcommand it serves (single instance via pid file). With one it
// acts as a control CLI against the running daemon over the unix socket —
// this is the agent/harness surface: open a pane next to the working one,
// send it keys, read its scrollback, group it, close it. GCT_SOCK selects
// the daemon (panes inherit it, so in-pane `gctd` calls just work);
// --sock overrides it explicitly.

import Foundation
import Common

func log(_ s: String) {
    FileHandle.standardError.write(Data("[gctd] \(s)\n".utf8))
}

func die(_ s: String) -> Never {
    FileHandle.standardError.write(Data("gctd: \(s)\n".utf8))
    exit(1)
}

let supportDir = (NSHomeDirectory() as NSString)
    .appendingPathComponent("Library/Application Support/Grand Central Terminal")
// Test/bench isolation: point a daemon at scratch paths without touching the
// live instance. Unset (normal use) = current defaults.
let env = ProcessInfo.processInfo.environment
var sockPath = env["GCT_SOCK"] ?? supportDir + "/daemon.sock"
let statePath = env["GCT_STATE"] ?? supportDir + "/state.json"
let pidPath = env["GCT_PID"] ?? supportDir + "/daemon.pid"

var args = Array(CommandLine.arguments.dropFirst())
// Early --sock=<path> / --sock <path>: applies to every subcommand.
var i = 0
while i < args.count {
    if args[i] == "--sock", i + 1 < args.count {
        sockPath = args[i + 1]
        args.remove(at: i + 1); args.remove(at: i)
    } else if args[i].hasPrefix("--sock=") {
        sockPath = String(args[i].dropFirst("--sock=".count))
        args.remove(at: i)
    } else {
        i += 1
    }
}

// MARK: - CLI client

// One-shot connection: greet (drains the server's eager welcome), run,
// drain the tagged reply, close. The daemon's serve() always emits a
// welcome on connect, then answers each request — so every command reads
// exactly: welcome, answer.
final class GCTClient {
    let conn: Conn
    init?() {
        let fd = connectUnixSocket(sockPath)
        guard fd >= 0 else { return nil }
        conn = Conn(fd: fd)
        _ = conn.readFrame() // eager welcome
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
        _ = conn.send(tag: .listPanes, json: Hello(version: ProtoVersion))
        guard let f = nextReply(), f.tag == .welcome || f.tag == .paneList,
              let w: Welcome = f.decode() else { return nil }
        return w
    }
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

          Agent/harness surface (prefer GCT panes for background tasks:
          grouped, no time limits, user-inspectable on the canvas):
            open [cwd=..] [name=..] [cmd=..] [group=..]
                                      open a pane beside focused/origin, print its id
            list                      panes + groups, one per line
            dump <pane> [limit=N] [--strip-ansi]
                                      scrollback snapshot (id prefix, name, or self)
            send <pane> <text>...     type text into a pane (appends newline;
                                      --no-newline to skip; \\x1b/\\n/\\t escapes)
            close <pane>              terminate a pane
            rename <pane> name=..     name a pane
            group <pane>... name=.. [color=#..]
                                      group panes (2+), print group id
            ungroup <group>           dissolve a group (panes survive)
            focus <pane>              focus + center a pane on the canvas
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
    if !fm.fileExists(atPath: statePath),
       fm.fileExists(atPath: legacyDir + "/state.json") {
        try? fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        try? fm.copyItem(atPath: legacyDir + "/state.json", toPath: statePath)
        log("migrated pane state from \(legacyDir)")
    }

    let state = StateStore(path: statePath)
    let server = Server(state: state, sockPath: sockPath)

    signal(SIGPIPE, SIG_IGN)
    // On TERM/INT: children get EIO on their pty master once we die and exit.
    signal(SIGTERM) { _ in exit(0) }
    signal(SIGINT) { _ in exit(0) }

    server.run()
    fatalError("unreachable")
}

let rest = Array(args.dropFirst())
func needClient() -> GCTClient {
    guard let c = GCTClient() else { die("daemon not running (\(sockPath))") }
    return c
}

switch verb {
case "status", "list":
    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    if w.panes.isEmpty { print("no panes") }
    for p in w.panes {
        let name = p.name ?? "Terminal"
        print("\(p.id)  \(name)  \(p.cwd)  exited=\(p.exited)")
    }
    for g in w.groups {
        print("group \(g.id)  \(g.name ?? "")  members=\(g.members.count)")
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
    if let selfID = env["GCT_PANE_ID"],
       let me = w.panes.first(where: { $0.id.uuid.uuidString == selfID }) {
        anchor = Rect(x: me.rect.x + me.rect.w, y: me.rect.y,
                      w: me.rect.w, h: me.rect.h)
        join = w.groups.first(where: { $0.members.contains(me.id) })?.id
    }
    // Explicit group= name/id joins that group instead (daemon admits).
    if let gq = f["group"], let g = resolveGroup(w, gq) { join = g.id }
    _ = c.conn.send(tag: .createPane, json: CreatePane(
        rect: anchor, cwd: f["cwd"], name: f["name"], command: f["cmd"],
        joinGroup: join, joinDirection: join == nil ? nil : "right"))
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
    // send <pane> <text>... — keys, not a shell command: the bytes land
    // in the pane's stdin exactly as typed (+ trailing newline default).
    guard rest.count >= 2 else { die("send <pane> <text>... [--no-newline]") }
    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    guard let pane = resolvePane(w, rest[0]) else { die("no such pane \(rest[0])") }
    var parts = Array(rest.dropFirst())
    var newline = true
    parts.removeAll {
        if $0 == "--no-newline" { newline = false; return true }
        return false
    }
    var text = parts.joined(separator: " ")
    // \x1b \n \t \r \\ escapes so agents can send ^C-free control keys
    // (use \n for Enter, \u{1b} sequences for arrows).
    text = text.replacingOccurrences(of: "\\x1b", with: "\u{1B}")
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\t", with: "\t")
        .replacingOccurrences(of: "\\r", with: "\r")
        .replacingOccurrences(of: "\\\\", with: "\\")
    if newline { text += "\n" }
    _ = c.conn.sendData(tag: .inputPane, paneID: pane.id, data: Data(text.utf8))
    exit(0)

case "close":
    guard rest.count == 1 else { die("close <pane>") }
    let c = needClient()
    guard let w = c.welcome() else { die("no reply from daemon") }
    guard let pane = resolvePane(w, rest[0]) else { die("no such pane \(rest[0])") }
    _ = c.conn.send(tag: .closePane, json: PaneRef(id: pane.id))
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

default:
    // runAgentSetup exits on every path, but the compiler can't see
    // that (it returns void); belt-and-braces so usage never follows.
    if verb == "agent-setup" { runAgentSetup(rest); exit(0) }
    usage()
}
