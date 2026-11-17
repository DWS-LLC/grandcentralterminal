// CLI plumbing for the gctd subcommands: exit statuses, error helpers,
// target-id helpers and the JSON shapes behind `--json`. Scripts get a
// stable surface: full ids, fixed keys, a status that says what went wrong.
//
//   gctd list --json | jq -r '.panes[] | select(.exited) | .id'
//   gctd open --wait cmd="make test" || echo "tests failed: $?"

import Foundation
import Common

// Exit statuses. `wait` and `open --wait` return the pane program's own.
enum CLIExit: Int32 {
    case ok = 0
    case failed = 1
    case usage = 2        // invalid command line
    case notFound = 3     // target missing or ambiguous
    case unreachable = 4  // daemon not running / link gone
    case timedOut = 124   // wait for= ran out, like timeout(1)
}

let PaneKind = "pane"
let GroupKind = "group"
// Shortest id suffix that may name a pane or group.
let MinSuffix = 4
// Longest status a process can exit with.
private let maxExitStatus: Int32 = 255

func bad(_ s: String) -> Never {
    die(s, .usage)
}

func missing(_ what: String) -> Never {
    die("no such \(what)", .notFound)
}

// `pane:<uuid>` and `<uuid>` name the same thing.
func untyped(_ raw: String, kind: String) -> String {
    let tag = kind + ":"
    return raw.hasPrefix(tag) ? String(raw.dropFirst(tag.count)) : raw
}

func paneRow(_ p: PaneMeta) -> String {
    "\(p.id.uuid.uuidString)  \(p.name ?? p.title ?? "Terminal")  \(p.cwd)"
}

func groupRow(_ g: GroupMeta) -> String {
    "\(g.id.uuid.uuidString)  \(g.name ?? "")  members=\(g.members.count)"
}

// Change nothing, show what matched, exit notFound.
func ambiguous(_ query: String, _ rows: [String]) -> Never {
    var out = "gctd: \(query) matches \(rows.count); use more of the id\n"
    for r in rows { out += "  \(r)\n" }
    FileHandle.standardError.write(Data(out.utf8))
    exit(CLIExit.notFound.rawValue)
}

// MARK: - wait

let staleDaemon = "daemon predates wait (proto < \(WaitProtoVersion)); relaunch the app to refresh it"
let staleVerbs = "daemon predates font and session (proto < \(CanvasVerbProtoVersion)); relaunch the app to refresh it"
let staleKeepOpen = "daemon predates keep-open (proto < \(KeepOpenProtoVersion)); relaunch the app to refresh it"
let stalePeers = "daemon predates hosts (proto < \(PeerProtoVersion)); relaunch the app to refresh it"

// Block on the pane's paneExit and leave with the program's status. The
// connection is already a subscriber, so an exit between the lookup and
// here still arrives; one that happened earlier is answered from the
// daemon's recent-exit table (waitPane).
func awaitExit(_ c: GCTClient, _ id: PaneID, limit: TimeInterval? = nil) -> Never {
    fflush(stdout)
    if let limit {
        // The main thread sits in a blocking read; a timer ends the process.
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
            fputs("gctd: pane still running after \(Int(limit))s\n", stderr)
            exit(CLIExit.timedOut.rawValue)
        }
    }
    while let f = c.conn.readFrame() {
        if f.tag == .errorReply { missing("pane \(id)") }
        guard f.tag == .paneExit, let e: PaneExit = f.decode(), e.id == id else { continue }

        guard e.code >= 0 else {
            fputs("gctd: pane closed without a status\n", stderr)
            exit(CLIExit.failed.rawValue)
        }
        exit(min(e.code, maxExitStatus))
    }
    die("daemon went away", .unreachable)
}

// MARK: - JSON

struct RectJSON: Encodable {
    var x: Double, y: Double, w: Double, h: Double
}

struct PaneJSON: Encodable {
    var kind = PaneKind
    var id: String
    var name: String
    var cwd: String
    var host: String
    var exited: Bool
    var offline: Bool
    var floating: Bool
    var rect: RectJSON
    var title: String?
    var proc: String?
    var exe: String?
    var repoRoot: String?
    var worktree: String?
    var parent: String?
    var group: String?
    var groupName: String?
    var guestOf: String?
}

struct GroupJSON: Encodable {
    var kind = GroupKind
    var id: String
    var name: String?
    var color: String?
    var members: [String]
}

struct PeerJSON: Encodable {
    var name: String
    var up: Bool
    var panes: Int
}

struct TieJSON: Encodable {
    struct Strand: Encodable { var parent: String, child: String }
    var id: String
    var at: Double
    var strands: [Strand]
}

struct ListJSON: Encodable {
    var version: UInt16
    var panes: [PaneJSON]
    var guests: [PaneJSON]
    var groups: [GroupJSON]
    var peers: [PeerJSON]
    var ties: [TieJSON]
}

// Auto names need the whole set (they disambiguate against each other).
func displayNames(_ w: Welcome) -> [PaneID: String] {
    let auto = AutoName.names(w.panes.map {
        AutoName.Pane(id: $0.id, cwd: $0.cwd, proc: $0.proc, title: $0.title,
                      repoRoot: $0.repoRoot, worktree: $0.worktree)
    }, home: daemonHome())
    return Dictionary(uniqueKeysWithValues: w.panes.map { ($0.id, $0.name ?? auto[$0.id] ?? "Terminal") })
}

func paneJSON(_ w: Welcome, _ p: PaneMeta, names: [PaneID: String]) -> PaneJSON {
    let group = w.groups.first { $0.members.contains(p.id) }
    return PaneJSON(
        id: p.id.uuid.uuidString,
        name: names[p.id] ?? p.name ?? "Terminal",
        cwd: p.cwd, host: p.host, exited: p.exited, offline: p.offline,
        floating: p.floating,
        rect: RectJSON(x: p.rect.x, y: p.rect.y, w: p.rect.w, h: p.rect.h),
        title: p.title, proc: p.proc, exe: p.exe, repoRoot: p.repoRoot, worktree: p.worktree,
        parent: p.parent?.uuid.uuidString,
        group: group?.id.uuid.uuidString, groupName: group?.name,
        guestOf: p.guestOf)
}

func peersJSON(_ w: Welcome) -> [PeerJSON] {
    w.peers.map { peer in
        PeerJSON(name: peer.name, up: peer.up,
                 panes: w.panes.filter { $0.host == peer.name }.count)
    }
}

func listJSON(_ w: Welcome) -> ListJSON {
    let names = displayNames(w)
    return ListJSON(
        version: w.version,
        panes: w.panes.map { paneJSON(w, $0, names: names) },
        guests: w.guests.map { paneJSON(w, $0, names: names) },
        groups: w.groups.map {
            GroupJSON(id: $0.id.uuid.uuidString, name: $0.name, color: $0.color,
                      members: $0.members.map(\.description))
        },
        peers: peersJSON(w),
        ties: w.ties.map { t in
            TieJSON(id: t.id, at: t.s, strands: t.strands.map {
                .init(parent: $0.parent.description, child: $0.child.description)
            })
        })
}

// One line, fixed key order: diffable and jq-friendly.
func printJSON(_ v: some Encodable) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? enc.encode(v) else { die("json encode failed") }

    print(String(decoding: data, as: UTF8.self))
}

// `gctd inspect` as key: value lines, only the keys that have a value.
func inspectLines(_ p: PaneJSON) -> [String] {
    let state = p.exited ? "exited" : (p.offline ? "offline" : "running")
    var rows: [(String, String?)] = [
        ("id", p.id), ("name", p.name), ("state", state), ("host", p.host),
        ("cwd", p.cwd), ("proc", p.proc), ("exe", p.exe), ("title", p.title),
        ("repo", p.repoRoot), ("worktree", p.worktree),
        ("group", p.group.map { "\(p.groupName ?? "") (\($0))" }),
        ("parent", p.parent), ("guest-of", p.guestOf),
        ("rect", "\(Int(p.rect.x)),\(Int(p.rect.y)) \(Int(p.rect.w))x\(Int(p.rect.h))"),
    ]
    if p.floating { rows.append(("floating", "yes")) }

    return rows.compactMap { key, value in
        value.map { "\(key.padding(toLength: inspectKeyWidth, withPad: " ", startingAt: 0))\($0)" }
    }
}
private let inspectKeyWidth = 10
