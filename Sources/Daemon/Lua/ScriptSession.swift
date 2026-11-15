// A script's view of the daemon: one socket, a live mirror of the layout, and
// the events the frames imply. No Lua in here, no waiting either: the loop owns
// scheduling, this owns the protocol.
//
//   daemon ──frames──► ingest ──► world (panes, groups, ties, peers)
//                          └────► [ScriptEvent]  pane_created, terminal.bell, ...
//
// The mirror is built from broadcasts alone, so an event is a frame seen once,
// never a diff against a snapshot taken in between.

import Foundation
import Common

struct ScriptEvent {
    let name: String
    var pane: PaneID?
    var fields: [String: Any] = [:]
    // Arrival order, set when the loop buffers it.
    var seq = 0
}

enum Evt {
    static let paneCreated = "pane_created"
    static let paneClosed = "pane_closed"
    static let paneRenamed = "pane_renamed"
    static let paneLink = "pane_link_changed"
    static let groupCreated = "group_created"
    static let groupChanged = "group_changed"
    static let groupClosed = "group_closed"
    static let tieChanged = "tie_changed"
    static let tieRemoved = "tie_removed"
    static let hostUp = "host_up"
    static let hostDown = "host_down"
    static let viewChanged = "view_changed"
    static let exited = "terminal.child_exited"
    static let pwd = "terminal.pwd_changed"
    static let process = "terminal.process_changed"
    static let terminalPrefix = "terminal."
    // Matches every terminal.* event, like Rex's block_event.
    static let bell = PaneEventName.bell
    static let title = PaneEventName.title
    static let notification = PaneEventName.notification
    static let anyTerminal = "terminal_event"
    // Rex's name for the same catch-all, so its scripts port as they are.
    static let blockEvent = "block_event"
}

final class ScriptSession {
    private let conn: Conn
    private(set) var world: Welcome
    private var revision = 0

    // The pane this script was started from, for defaults and `self`.
    var home: PaneID?

    // What the canvas told us that the daemon never knew: the status records
    // each pane holds (by record id), its grid, and how many syncs finished.
    private var statuses = [PaneID: [String: [String: Any]]]()
    private var grids = [PaneID: [String: Any]]()
    private(set) var syncs = 0
    private var syncAsked = false

    var version: UInt16 { world.version }

    init?(client: GCTClient) {
        guard let w = client.welcome() else { return nil }

        conn = client.conn
        world = w
        home = env["GCT_PANE_ID"].flatMap(PaneID.init(string:))

        // An older daemon would drop us for an unknown tag: no canvas events.
        if w.version >= EventProtoVersion {
            client.conn.send(tag: .subscribeEvents, json: Hello(version: ProtoVersion))
        }
    }

    // MARK: Wire

    // Frames land on the sink from a reader thread; nil means the socket died.
    func startReader(_ sink: @escaping (Frame?) -> Void) {
        let c = conn
        Thread {
            while let f = c.readFrame() {
                sink(f)
            }
            sink(nil)
        }.start()
    }

    func send(_ tag: MsgTag, _ json: some Codable & Sendable) throws {
        guard conn.send(tag: tag, json: json) else { throw ScriptError("daemon went away") }
    }

    func sendRaw(_ tag: MsgTag, json: Data) throws {
        guard conn.sendRaw(tag: tag, json: json) else { throw ScriptError("daemon went away") }
    }

    func sendKeys(_ id: PaneID, _ data: Data) throws {
        guard conn.sendData(tag: .inputPane, paneID: id, data: data) else { throw ScriptError("daemon went away") }
    }

    func hangUp() {
        conn.close()
    }

    // Ask for the whole layout again; the barrier a request ends on.
    func askLayout() throws {
        try send(.listPanes, Hello(version: ProtoVersion, token: cliAuthToken))
    }

    // Ask the canvas, once, to say again what it knows. The answer arrives as
    // frames; `syncs` moves when the last one has. False: nothing to ask.
    func askSync() throws -> Bool {
        guard version >= EventProtoVersion else { return false }
        guard !syncAsked else { return false }

        syncAsked = true
        try send(.canvasCommand, CanvasCommand(verb: .sync))
        return true
    }

    // The status records of a pane, ordered by record id.
    func records(of id: PaneID) -> [[String: Any]] {
        (statuses[id] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
    }

    func grid(of id: PaneID) -> [String: Any]? {
        grids[id]
    }

    // The foreground process, shaped as terminal.process_changed carries it.
    func processInfo(_ m: PaneMeta) -> [String: Any] {
        processFields(m)
    }

    // Authoritative reset, silently: only for a lookup that missed.
    func adopt(_ w: Welcome) {
        world = w
    }

    // MARK: Lookup

    private var every: [PaneMeta] { world.panes + world.guests }

    func pane(_ raw: String) throws -> PaneMeta {
        let q: String
        if raw == "self" {
            guard let home else { throw ScriptError("self needs a script started from a GCT pane") }
            q = home.description
        } else {
            q = untyped(raw, kind: PaneKind)
        }
        guard !q.isEmpty else { throw ScriptError("empty pane id") }

        let lower = q.lowercased()
        func uuid(_ p: PaneMeta) -> String { p.id.uuid.uuidString.lowercased() }

        if let hit = every.first(where: { uuid($0) == lower }) { return hit }

        let prefixed = every.filter { uuid($0).hasPrefix(lower) }
        if prefixed.count == 1 { return prefixed[0] }

        let local = world.panes.filter { ($0.name ?? "Terminal") == q }
        let named = local.isEmpty ? world.guests.filter { ($0.name ?? "Terminal") == q } : local
        if named.count == 1 { return named[0] }
        if named.count > 1 { throw ScriptError("\(q) names \(named.count) panes; use the id") }
        if prefixed.count > 1 { throw ScriptError("\(q) matches \(prefixed.count) panes; use more of the id") }

        guard q.count >= MinSuffix else { throw ScriptError("no such pane \(raw)") }

        let tailed = every.filter { uuid($0).hasSuffix(lower) }
        if tailed.count > 1 { throw ScriptError("\(q) matches \(tailed.count) panes; use more of the id") }
        guard let hit = tailed.first else { throw ScriptError("no such pane \(raw)") }

        return hit
    }

    func group(_ raw: String) throws -> GroupMeta {
        let q = untyped(raw, kind: GroupKind)
        guard !q.isEmpty else { throw ScriptError("empty group id") }

        let lower = q.lowercased()
        func uuid(_ g: GroupMeta) -> String { g.id.uuid.uuidString.lowercased() }

        if let hit = world.groups.first(where: { uuid($0) == lower }) { return hit }

        let prefixed = world.groups.filter { uuid($0).hasPrefix(lower) }
        if prefixed.count == 1 { return prefixed[0] }

        let named = world.groups.filter { ($0.name ?? "") == q }
        if named.count == 1 { return named[0] }
        if named.count + prefixed.count > 1 { throw ScriptError("\(q) matches several groups; use the id") }

        guard q.count >= MinSuffix else { throw ScriptError("no such group \(raw)") }

        let tailed = world.groups.filter { uuid($0).hasSuffix(lower) }
        guard tailed.count == 1 else { throw ScriptError("no such group \(raw)") }

        return tailed[0]
    }

    func tie(_ raw: String) throws -> TieMeta {
        let hits = world.ties.filter { $0.id.hasPrefix(raw.uppercased()) || $0.id == raw }
        guard hits.count == 1 else {
            throw ScriptError(hits.isEmpty ? "no such tie \(raw)" : "tie \(raw) is ambiguous")
        }

        return hits[0]
    }

    // MARK: Views

    // The same shape `gctd list --json` prints: scripts and shells agree.
    func view() -> [String: Any] {
        plain(listJSON(world)) as? [String: Any] ?? [:]
    }

    func info(_ p: PaneMeta) -> [String: Any] {
        plain(paneJSON(world, p, names: displayNames(world))) as? [String: Any] ?? [:]
    }

    private func plain(_ v: some Encodable) -> Any? {
        guard let data = try? JSONEncoder().encode(v) else { return nil }

        return try? ScriptJSON.decode(String(decoding: data, as: UTF8.self))
    }

    // MARK: Frames to events

    func ingest(_ f: Frame) -> [ScriptEvent] {
        var events = [ScriptEvent]()

        switch f.tag {
        case .paneCreated:
            guard let m: PaneCreated = f.decode() else { return [] }

            events = created(m.meta)
        case .paneMeta:
            guard let m: PaneMeta = f.decode() else { return [] }

            events = changed(m)
        case .paneExit:
            guard let e: PaneExit = f.decode() else { return [] }

            events = ended(e)
        case .groupCreated:
            guard let m: GroupCreated = f.decode() else { return [] }

            events = grouped(m.meta, Evt.groupCreated)
        case .groupMeta:
            guard let m: GroupMeta = f.decode() else { return [] }

            events = grouped(m, Evt.groupChanged)
        case .groupExit:
            guard let r: GroupRef = f.decode() else { return [] }

            world.groups.removeAll { $0.id == r.id }
            events = [ScriptEvent(name: Evt.groupClosed, fields: ["group_id": r.id.description])]
        case .tieMeta:
            guard let t: TieMeta = f.decode() else { return [] }

            upsert(&world.ties, t) { $0.id == t.id }
            events = [ScriptEvent(name: Evt.tieChanged, fields: ["tie_id": t.id])]
        case .tieExit:
            guard let r: TieRef = f.decode() else { return [] }

            world.ties.removeAll { $0.id == r.id }
            events = [ScriptEvent(name: Evt.tieRemoved, fields: ["tie_id": r.id])]
        case .peerState:
            guard let p: PeerInfo = f.decode() else { return [] }

            upsert(&world.peers, p) { $0.name == p.name }
            events = [ScriptEvent(name: p.up ? Evt.hostUp : Evt.hostDown, fields: ["host": p.name])]
        case .event:
            // From the canvas, not a layout change: no view_changed behind it.
            guard let e: PaneEvent = f.decode() else { return [] }

            return relayed(e)
        default:
            return []
        }

        // Every frame above reshapes the layout, named event or not.
        revision += 1
        return events + [ScriptEvent(name: Evt.viewChanged, fields: ["revision": revision])]
    }

    private func relayed(_ e: PaneEvent) -> [ScriptEvent] {
        var fields = [String: Any]()
        if let text = e.payload, let more = try? ScriptJSON.decode(text) as? [String: Any] { fields = more }
        if let t = e.title { fields["title"] = t }
        if let b = e.body { fields["body"] = b }

        // Not events: the canvas filling in what block.call will be asked.
        if e.name == PaneEventName.synced {
            syncs += 1
            return []
        }
        if e.name == PaneEventName.sizeState {
            if let id = e.id { grids[id] = fields }
            return []
        }

        remember(e, fields)

        if e.name == PaneEventName.title, let id = e.id, let i = world.panes.firstIndex(where: { $0.id == id }) {
            world.panes[i].title = e.title
        }

        return [ScriptEvent(name: e.name, pane: e.id, fields: fields)]
    }

    // Keep the status records current: a change sets one, a removal drops each id.
    private func remember(_ e: PaneEvent, _ fields: [String: Any]) {
        guard let id = e.id else { return }

        switch e.name {
        case PaneEventName.statusChanged:
            guard let key = fields["id"] as? String, let record = fields["record"] as? [String: Any] else { return }

            statuses[id, default: [:]][key] = record
        case PaneEventName.statusRemoved:
            for key in fields["ids"] as? [Any] ?? [] {
                guard let key = key as? String else { continue }

                statuses[id]?.removeValue(forKey: key)
            }
        default:
            break
        }
    }

    private func upsert<T>(_ list: inout [T], _ item: T, where match: (T) -> Bool) {
        guard let i = list.firstIndex(where: match) else {
            list.append(item)
            return
        }

        list[i] = item
    }

    private func created(_ meta: PaneMeta) -> [ScriptEvent] {
        upsert(&world.panes, meta) { $0.id == meta.id }

        var fields: [String: Any] = ["host": meta.host, "cwd": meta.cwd]
        if let name = meta.name { fields["pane_name"] = name }
        return [ScriptEvent(name: Evt.paneCreated, pane: meta.id, fields: fields)]
    }

    // What differs between the pane we knew and the one just sent.
    private func changed(_ meta: PaneMeta) -> [ScriptEvent] {
        guard meta.guestOf == nil else {
            upsert(&world.guests, meta) { $0.id == meta.id }
            return []
        }
        guard let i = world.panes.firstIndex(where: { $0.id == meta.id }) else {
            world.panes.append(meta)
            return []
        }

        let old = world.panes[i]
        world.panes[i] = meta
        var out = [ScriptEvent]()

        if old.name != meta.name {
            out.append(ScriptEvent(name: Evt.paneRenamed, pane: meta.id,
                                   fields: ["pane_name": meta.name ?? "", "old_name": old.name ?? ""]))
        }
        if old.cwd != meta.cwd {
            out.append(ScriptEvent(name: Evt.pwd, pane: meta.id,
                                   fields: ["pwd": "file://" + meta.cwd, "cwd": meta.cwd]))
        }
        if old.proc != meta.proc {
            out.append(ScriptEvent(name: Evt.process, pane: meta.id, fields: processFields(meta)))
        }
        if old.offline != meta.offline {
            out.append(ScriptEvent(name: Evt.paneLink, pane: meta.id, fields: ["offline": meta.offline]))
        }

        return out
    }

    // proc is the foreground command line; nil is an idle shell.
    private func processFields(_ m: PaneMeta) -> [String: Any] {
        guard let line = m.proc else { return [:] }

        let name = line.split(separator: " ").first.map(String.init) ?? line
        return ["foreground": ["name": name, "cmd": line, "cwd": m.cwd] as [String: Any]]
    }

    private func ended(_ e: PaneExit) -> [ScriptEvent] {
        // Not in the layout: long gone, or not ours to announce.
        guard let known = world.panes.first(where: { $0.id == e.id }) else { return [] }

        // A kept pane announces twice: when it ends, and again when it's closed.
        let first = !known.exited
        var out = [ScriptEvent]()

        if first, e.code != ExitUnknown {
            out.append(ScriptEvent(name: Evt.exited, pane: e.id,
                                   fields: ["exit_code": Int(e.code), "kept": e.kept]))
        }

        guard !e.kept else {
            if let i = world.panes.firstIndex(where: { $0.id == e.id }) { world.panes[i].exited = true }
            return out
        }

        world.panes.removeAll { $0.id == e.id }
        statuses.removeValue(forKey: e.id)
        grids.removeValue(forKey: e.id)
        for i in world.groups.indices { world.groups[i].members.removeAll { $0 == e.id } }
        out.append(ScriptEvent(name: Evt.paneClosed, pane: e.id))
        return out
    }

    private func grouped(_ g: GroupMeta, _ name: String) -> [ScriptEvent] {
        upsert(&world.groups, g) { $0.id == g.id }

        let fields: [String: Any] = ["group_id": g.id.description, "group_name": g.name ?? "",
                                     "members": g.members.map(\.description)]
        return [ScriptEvent(name: name, fields: fields)]
    }
}
