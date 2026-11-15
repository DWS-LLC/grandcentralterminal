// What a script can do to GCT, as plain Swift: each op takes a dictionary and
// returns a value or throws. The Lua layer owns the marshalling; ops never see
// a stack, and the CLI verbs they mirror stay untouched.
//
//   gct.pane.open{cmd="make"}  ─►  "pane.open"  ─►  CreatePane frame  ─►  daemon
//
// Pane arguments take what `gctd` takes: a uuid, a unique prefix or suffix, an
// exact name, or "self". Left out, they default to the pane the script is
// acting for (its own, or the one an event came from).

import Foundation
import Common

typealias ScriptOp = (ScriptArgs) throws -> Any?

struct ScriptArgs {
    let raw: [String: Any]

    private func wrong(_ key: String, _ want: String) -> ScriptError {
        ScriptError("\(key) must be \(want)")
    }

    func string(_ key: String) throws -> String? {
        guard let v = raw[key] else { return nil }
        guard let s = v as? String else { throw wrong(key, "a string") }

        return s
    }

    func double(_ key: String) throws -> Double? {
        switch raw[key] {
        case nil: return nil
        case let d as Double where d.isFinite: return d
        case let i as Int: return Double(i)
        default: throw wrong(key, "a number")
        }
    }

    func flag(_ key: String) throws -> Bool {
        guard let v = raw[key] else { return false }
        guard let b = v as? Bool else { throw wrong(key, "true or false") }

        return b
    }

    func list(_ key: String) throws -> [Any] {
        guard let v = raw[key] else { return [] }
        guard let a = v as? [Any] else { throw wrong(key, "a list") }

        return a
    }

    // {x=, y=, w=, h=}
    func rect(_ key: String) throws -> Rect? {
        guard let v = raw[key] else { return nil }
        guard let m = v as? [String: Any] else { throw wrong(key, "a table with x, y, w, h") }

        let box = ScriptArgs(raw: m)
        guard let x = try box.double("x"), let y = try box.double("y"),
              let w = try box.double("w"), let h = try box.double("h"), w > 0, h > 0 else {
            throw wrong(key, "a table with x, y, w, h (w and h above zero)")
        }

        return Rect(x: x, y: y, w: w, h: h)
    }

    // The pane named by `pane`, `pane_id` or Rex's `block_id`, if any is there.
    func paneRef() throws -> String? {
        try string("pane") ?? string("pane_id") ?? string("block_id")
    }
}

private extension Rect {
    // The box around this and every rect given.
    func union(_ others: [Rect]) -> Rect {
        let all = [self] + others
        let x0 = all.map(\.x).min() ?? x, y0 = all.map(\.y).min() ?? y
        let x1 = all.map { $0.x + $0.w }.max() ?? x + w, y1 = all.map { $0.y + $0.h }.max() ?? y + h
        return Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }
}

final class ScriptOps {
    private let loop: ScriptLoop
    // The pane calls fall back to: set by the runtime around each callback.
    var contextPane: () -> PaneID? = { nil }

    private var session: ScriptSession { loop.session }

    init(loop: ScriptLoop) {
        self.loop = loop
    }

    private lazy var blocks = ScriptBlocks(
        loop: loop, dump: { try self.dump($0) }, relay: { try self.relay($0) },
        need: { try self.needVersion($0, $1) })

    lazy var table: [String: ScriptOp] = [
        "view": { _ in self.session.view() },
        "hosts": { _ in ["hosts": self.session.view()["peers"] ?? []] },
        "servers": { _ in self.session.world.peers.map(\.name) },
        "block.call": { try self.blockCall($0) },
        "pane.list": { _ in ["panes": self.session.view()["panes"] ?? []] },
        "pane.inspect": { try self.inspect($0) },
        "pane.open": { try self.open($0) },
        "layout.open": { try self.openLayout($0) },
        "pane.close": { try self.close($0) },
        "pane.rename": { try self.rename($0) },
        "pane.send": { try self.sendKeys($0) },
        "pane.dump": { try self.dump($0) },
        "pane.notify": { try self.notify($0) },
        "pane.focus": { try self.focus($0) },
        "pane.move": { try self.move($0) },
        "pane.wait": { try self.waitFor($0) },
        "group.create": { try self.createGroup($0) },
        "group.delete": { try self.deleteGroup($0) },
        "tie.create": { try self.createTie($0) },
        "tie.delete": { try self.deleteTie($0) },
        "camera": { try self.camera($0) },
        "font": { try self.font($0) },
        "session": { try self.showSession($0) },
        "client.queue": { try self.queue($0) },
        "client.press": { try self.press($0) },
        "call": { try self.call($0) },
    ]

    // Ops that also take positional arguments, Rex style: gct.call(method, args).
    // Leading strings become the named ones, then a table goes under "args".
    static let positional: [String: [String]] = [
        "call": ["method"], "client.queue": ["name"], "client.press": ["keys"], "block.call": ["creator", "method"],
    ]

    // MARK: Lookup

    // A missed lookup may just be stale: ask for the layout once, then give up.
    private func lookup(_ ref: String) throws -> PaneMeta {
        do {
            return try session.pane(ref)
        } catch let e as ScriptError where e.message.hasPrefix("no such") {
            try refresh()
            return try session.pane(ref)
        }
    }

    private func refresh() throws {
        guard let f = try loop.request(.barrier, send: { try self.session.askLayout() }),
              let w: Welcome = f.decode() else { return }

        session.adopt(w)
    }

    private func pane(_ a: ScriptArgs) throws -> PaneMeta {
        if let ref = try a.paneRef() { return try lookup(ref) }
        guard let id = contextPane() else { throw ScriptError("pane is required here") }

        return try lookup(id.description)
    }

    private func needVersion(_ v: UInt16, _ what: String) throws {
        guard session.version >= v else {
            throw ScriptError("daemon predates \(what) (proto < \(v)); relaunch the app to refresh it")
        }
    }

    // MARK: Panes

    private func inspect(_ a: ScriptArgs) throws -> Any? {
        session.info(try pane(a))
    }

    // Where a new pane (or a whole layout) lands, and what it's wired to.
    private struct Spot {
        var rect: Rect
        var join: GroupID?
        var link: PaneID?
        var parent: PaneID?
        var side: Side?
        var host: String?
        var cwd: String?
        var pinned: Bool
    }

    private func spot(_ a: ScriptArgs) throws -> Spot {
        let host = try a.string("host")
        if host != nil { try needVersion(PeerProtoVersion, "hosts") }

        let w = session.world
        var anchor = Self.defaultAnchor
        var join: GroupID?
        var link: PaneID?
        var parent: PaneID?
        var caller = contextPane().flatMap { id in w.panes.first { $0.id == id } }

        // parent= stands in for the caller: placed beside it, wired to it.
        if let ref = try a.string("parent") {
            let p = try lookup(ref)
            caller = p
            parent = p.id
        }
        if let me = caller {
            join = w.groups.first { $0.members.contains(me.id) }?.id
            link = me.id
        }
        if let ref = try a.string("group") {
            join = try session.group(ref).id
            link = nil
        }

        let side = try side(a)
        if side != nil, caller == nil { throw ScriptError("side needs a calling pane or parent") }
        if side != nil, a.raw["rect"] != nil { throw ScriptError("side and rect both place the pane; pick one") }

        var extent = Extent(w: anchor.w, h: anchor.h)
        if let me = caller { extent = Extent(w: me.rect.w, h: me.rect.h) }
        if let s = try a.string("size") { extent = try size(s, caller: caller?.rect) }

        anchor.w = extent.w
        anchor.h = extent.h
        if let me = caller { anchor = Placement.beside(me.rect, side: side ?? .right, size: extent) }
        let pinned = a.raw["rect"] != nil
        if let r = try a.rect("rect") { anchor = r }

        // Like the CLI: no cwd opens where the script stands, unless the
        // pane runs on a peer, where that path means nothing.
        let cwd = try a.string("cwd") ?? (host == nil ? FileManager.default.currentDirectoryPath : nil)
        return Spot(rect: anchor, join: join, link: link, parent: parent, side: side,
                    host: host, cwd: cwd, pinned: pinned)
    }

    private func create(_ at: Spot, rect: Rect, name: String?, cmd: String?, cwd: String?,
                        keepOpen: Bool) throws -> PaneID {
        let reqID = UUID().uuidString
        let req = CreatePane(
            rect: rect, cwd: cwd ?? at.cwd, name: name, command: cmd,
            joinGroup: at.join, joinDirection: at.join == nil ? nil : (at.side ?? .right).rawValue,
            keepOpen: keepOpen,
            parent: at.parent ?? (at.pinned ? nil : at.link), reqID: reqID, host: at.host)

        let reply = try loop.request(.created(reqID)) { try self.session.send(.createPane, req) }
        guard let m: PaneCreated = reply?.decode() else { throw ScriptError("no reply from daemon") }

        return m.meta.id
    }

    private func open(_ a: ScriptArgs) throws -> Any? {
        let keepOpen = try a.flag("keep_open")
        if keepOpen { try needVersion(KeepOpenProtoVersion, "keep-open") }
        if keepOpen, a.raw["host"] != nil { throw ScriptError("keep_open runs the pane here; drop host") }

        let at = try spot(a)
        let id = try create(at, rect: at.rect, name: try a.string("name"), cmd: try a.string("cmd"),
                            cwd: nil, keepOpen: keepOpen)
        return ["pane_id": id.description]
    }

    // MARK: Layouts

    // A tree from gct.layout.block/horizontal/vertical, spread over one
    // region: a split hands its first child `ratio` of the width (horizontal)
    // or the height, top first (vertical); a block becomes a pane.
    //
    //   horizontal(0.4, A, vertical(0.5, B, C))
    //   ┌───────┬─────────┐
    //   │       │    B    │
    //   │   A   ├─────────┤
    //   │       │    C    │
    //   └───────┴─────────┘
    //
    // The daemon places every pane on its own, so a crowded canvas would
    // scatter the pieces. The first pane takes the whole region, which makes
    // the daemon find room for all of it; it then shrinks to its share and the
    // rest fill in around it.
    private func openLayout(_ a: ScriptArgs) throws -> Any? {
        guard let tree = a.raw["layout"] as? [String: Any] else { throw ScriptError("layout is required") }

        let at = try spot(a)
        var shares = try split(tree, over: at.rect, depth: 0)
        guard let head = shares.first else { throw ScriptError("layout has no blocks") }

        var ids = [PaneID]()
        let first = try leaf(head.node, head.rect.union(shares.map(\.rect)), at)
        ids.append(first)

        if shares.count > 1, session.version >= ArrangeProtoVersion,
           let landed = session.world.panes.first(where: { $0.id == first })?.rect {
            shares = try split(tree, over: landed, depth: 0)
            let move = PaneRect(id: first, rect: shares[0].rect)
            try loop.act { try self.session.send(.arrangePanes, ArrangePanes(moves: [move])) }
        }

        for share in shares.dropFirst() {
            ids.append(try leaf(share.node, share.rect, at))
        }

        var out: [String: Any] = ["pane_ids": ids.map(\.description)]
        guard let name = try a.string("name"), ids.count >= 2, at.join == nil else { return out }

        let reqID = UUID().uuidString
        let req = CreateGroup(name: name, color: try a.string("color"), members: ids, reqID: reqID)
        let reply = try loop.request(.groupCreated(reqID)) { try self.session.send(.createGroup, req) }
        if let m: GroupCreated = reply?.decode() { out["group_id"] = m.meta.id.description }
        return out
    }

    private static let maxLayoutDepth = 16
    // Where a pane with nothing to anchor to asks to go, like `gctd open`.
    private static let defaultAnchor = Rect(x: 0, y: 0, w: 900, h: 560)

    private typealias Share = (node: [String: Any], rect: Rect)

    // The blocks of the tree and the rect each gets, in reading order.
    private func split(_ node: [String: Any], over r: Rect, depth: Int) throws -> [Share] {
        guard depth < Self.maxLayoutDepth else { throw ScriptError("layout nests too deep") }
        guard let kind = node["kind"] as? String else { throw ScriptError("layout nodes come from gct.layout.*") }
        guard kind != "block" else { return [(node, r)] }

        let ratio = try ScriptArgs(raw: node).double("ratio") ?? 0.5
        guard ratio > 0, ratio < 1 else { throw ScriptError("a split's ratio is between 0 and 1") }
        guard let first = node["first"] as? [String: Any], let second = node["second"] as? [String: Any] else {
            throw ScriptError("a split takes two layouts")
        }

        var one = r, two = r
        switch kind {
        case "horizontal":
            one.w = r.w * ratio
            two.x = r.x + one.w
            two.w = r.w - one.w
        case "vertical":
            // y grows up: the first child is the top one.
            one.h = r.h * ratio
            two.h = r.h - one.h
            one.y = r.y + two.h
        default:
            throw ScriptError("unknown layout \(kind)")
        }

        return try split(first, over: one, depth: depth + 1) + split(second, over: two, depth: depth + 1)
    }

    // One block: command (a list or a string), cwd, name, initial_input, and
    // exit = {on_completion = false} to keep the pane after its program ends.
    private func leaf(_ node: [String: Any], _ r: Rect, _ at: Spot) throws -> PaneID {
        let spec = ScriptArgs(raw: node["block"] as? [String: Any] ?? [:])
        let options = ScriptArgs(raw: spec.raw["options"] as? [String: Any] ?? spec.raw)

        var cmd: String?
        switch options.raw["command"] {
        case let s as String: cmd = s
        case let list as [Any]: cmd = list.compactMap { $0 as? String }.map(shellQuoted).joined(separator: " ")
        default: break
        }

        let exit = options.raw["exit"] as? [String: Any]
        let keep = exit?["on_completion"] as? Bool == false
        if keep { try needVersion(KeepOpenProtoVersion, "keep-open") }

        let id = try create(at, rect: r, name: try spec.string("label") ?? spec.string("name"),
                            cmd: cmd, cwd: try options.string("cwd"), keepOpen: keep)

        if let typed = try options.string("initial_input"), !typed.isEmpty {
            try session.sendKeys(id, Data(typed.utf8))
        }

        return id
    }

    private func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func side(_ a: ScriptArgs) throws -> Side? {
        guard let raw = try a.string("side") else { return nil }
        guard let s = Side(rawValue: raw) else { throw ScriptError("side is right, left, above or below, got \(raw)") }

        return s
    }

    private func size(_ raw: String, caller: Rect?) throws -> Extent {
        do {
            return try Placement.size(raw, caller: caller)
        } catch SizeError.needsCaller {
            throw ScriptError("size \(raw) is a share of the calling pane; there is none (use w,h)")
        } catch {
            throw ScriptError("size is w,h or w%,h%, got \(raw)")
        }
    }

    private func close(_ a: ScriptArgs) throws -> Any? {
        let p = try pane(a)
        try loop.act { try self.session.send(.closePane, PaneRef(id: p.id)) }
        return [:] as [String: Any]
    }

    private func rename(_ a: ScriptArgs) throws -> Any? {
        let p = try pane(a)
        let name = try a.string("name") ?? ""
        try loop.act { try self.session.send(.renamePane, RenamePane(id: p.id, name: name.isEmpty ? nil : name)) }
        return [:] as [String: Any]
    }

    // Keys, not a command: the bytes land in the pane's stdin as given.
    private func sendKeys(_ a: ScriptArgs) throws -> Any? {
        let p = try pane(a)
        var keys: Data
        switch a.raw["text"] {
        case let s as String: keys = Data(s.utf8)
        case let d as Data: keys = d
        default: throw ScriptError("text must be a string")
        }
        guard !keys.isEmpty else { throw ScriptError("text is empty") }

        if try a.flag("paste") {
            keys = Data(bracketedPasteStart.utf8) + keys + Data(bracketedPasteEnd.utf8)
        }
        if a.raw["enter"] as? Bool ?? true { keys.append(UInt8(ascii: "\n")) }

        try session.sendKeys(p.id, keys)
        return [:] as [String: Any]
    }

    private func dump(_ a: ScriptArgs) throws -> Any? {
        let p = try pane(a)
        let limit = Int(try a.double("limit") ?? 0)
        let reply = try loop.request(.dump(p.id)) { try self.session.send(.dumpPane, DumpPane(id: p.id, limit: limit)) }
        guard let d: PaneDump = reply?.decode() else { throw ScriptError("no reply from daemon") }

        var text = d.data
        if d.base64, let bytes = Data(base64Encoded: d.data) {
            text = String(data: bytes, encoding: .utf8) ?? "<binary>"
        }
        if try a.flag("strip_ansi") { text = stripANSI(text) }

        return ["text": text, "truncated": d.truncated, "dropped": Int(d.dropped), "bytes": d.bytes]
    }

    private func notify(_ a: ScriptArgs) throws -> Any? {
        let p = try pane(a)
        guard let body = try a.string("body"), !body.isEmpty else { throw ScriptError("body is required") }

        let note = PaneNotify(id: p.id, title: try a.string("title"), body: body)
        try loop.act { try self.session.send(.notifyPane, note) }
        return [:] as [String: Any]
    }

    private func focus(_ a: ScriptArgs) throws -> Any? {
        let p = try pane(a)
        try loop.act { try self.session.send(.focusPane, PaneRef(id: p.id)) }
        return [:] as [String: Any]
    }

    private func move(_ a: ScriptArgs) throws -> Any? {
        let p = try pane(a)
        guard let rect = try a.rect("rect") else { throw ScriptError("rect is required") }

        try loop.act { try self.session.send(.movePane, MovePane(id: p.id, rect: rect)) }
        return [:] as [String: Any]
    }

    // gct.block.call(creator, method, {pane = ...}): a method on the pane's terminal.
    private func blockCall(_ a: ScriptArgs) throws -> Any? {
        guard let creator = try a.string("creator"), let method = try a.string("method") else {
            throw ScriptError("gct.block.call(creator, method[, args])")
        }

        let args = ScriptArgs(raw: a.raw["args"] as? [String: Any] ?? [:])
        return try blocks.call(creator, method, args, on: try pane(args))
    }

    // MARK: Waiting on a pane

    // The program's exit status. A pane still running is awaited on the event
    // stream; one that already ended (or is gone) is asked of the daemon, which
    // remembers recent exits.
    private func waitFor(_ a: ScriptArgs) throws -> Any? {
        let limit = try a.double("timeout").map { Date().addingTimeInterval($0) }
        let found = try? pane(a)
        guard let found, !found.exited else { return try ended(a, found) }

        let id = found.id
        var hit: ScriptEvent?
        let end = loop.pump(until: limit, dispatch: .allow) {
            hit = self.loop.takeEvent { $0.pane == id && ($0.name == Evt.exited || $0.name == Evt.paneClosed) }
            return hit != nil
        }

        switch end {
        case .done:
            guard let code = hit?.fields["exit_code"] else { return ["closed": true] }

            return ["exit_code": code]
        case .timeout: throw ScriptError("timeout")
        case .hangup: throw ScriptError("daemon went away")
        }
    }

    private func ended(_ a: ScriptArgs, _ known: PaneMeta?) throws -> Any? {
        try needVersion(WaitProtoVersion, "wait")

        let raw = try a.paneRef() ?? contextPane()?.description ?? ""
        guard let id = known?.id ?? PaneID(string: untyped(raw, kind: PaneKind)) else {
            throw ScriptError("no such pane \(raw)")
        }

        let reply = try loop.request(.exit(id)) { try self.session.send(.waitPane, PaneRef(id: id)) }
        guard let e: PaneExit = reply?.decode() else { throw ScriptError("no reply from daemon") }
        guard e.code >= 0 else { return ["closed": true] }

        return ["exit_code": Int(e.code)]
    }

    // MARK: Groups and ties

    private func createGroup(_ a: ScriptArgs) throws -> Any? {
        let ids = try a.list("panes").map { item -> PaneID in
            guard let ref = item as? String else { throw ScriptError("panes is a list of pane ids or names") }

            return try lookup(ref).id
        }
        guard ids.count >= 2 else { throw ScriptError("a group needs 2+ panes") }

        let reqID = UUID().uuidString
        let req = CreateGroup(name: try a.string("name"), color: try a.string("color"), members: ids, reqID: reqID)
        let reply = try loop.request(.groupCreated(reqID)) { try self.session.send(.createGroup, req) }
        guard let m: GroupCreated = reply?.decode() else { throw ScriptError("no reply from daemon") }

        return ["group_id": m.meta.id.description]
    }

    private func deleteGroup(_ a: ScriptArgs) throws -> Any? {
        guard let ref = try a.string("group") else { throw ScriptError("group is required") }

        let g = try session.group(ref)
        try loop.act { try self.session.send(.deleteGroup, GroupRef(id: g.id)) }
        return [:] as [String: Any]
    }

    private func createTie(_ a: ScriptArgs) throws -> Any? {
        guard let parentRef = try a.string("parent") else { throw ScriptError("parent is required") }

        let parent = try lookup(parentRef)
        let at = try a.double("at") ?? defaultTieAt
        guard (0...1).contains(at) else { throw ScriptError("at must be 0...1, got \(at)") }

        let strands = try a.list("children").map { item -> TieMeta.Strand in
            guard let ref = item as? String else { throw ScriptError("children is a list of pane ids or names") }

            let child = try lookup(ref)
            guard child.parent == parent.id else { throw ScriptError("\(ref) was not spawned by \(parentRef): no cable to tie") }

            return TieMeta.Strand(parent: parent.id, child: child.id)
        }
        guard strands.count >= 2 else { throw ScriptError("a tie bundles 2+ children") }

        let tie = TieMeta(s: at, strands: strands)
        try loop.request(.tie(tie.id)) { try self.session.send(.setTie, tie) }
        return ["tie_id": tie.id]
    }

    private func deleteTie(_ a: ScriptArgs) throws -> Any? {
        guard let ref = try a.string("tie") else { throw ScriptError("tie is required") }

        let t = try session.tie(ref)
        try loop.act { try self.session.send(.removeTie, TieRef(id: t.id)) }
        return [:] as [String: Any]
    }

    // MARK: The canvas

    private func relay(_ cmd: CanvasCommand) throws -> Any? {
        try loop.act { try self.session.send(.canvasCommand, cmd) }
        return [:] as [String: Any]
    }

    private func camera(_ a: ScriptArgs) throws -> Any? {
        var cmd = CanvasCommand(verb: .camera, x: try a.double("x"), y: try a.double("y"),
                                zoom: try a.double("zoom"), duration: try a.double("dur"))
        if let ref = try a.paneRef() { cmd.pane = try lookup(ref).id }
        return try relay(cmd)
    }

    private func font(_ a: ScriptArgs) throws -> Any? {
        try needVersion(CanvasVerbProtoVersion, "font")

        var cmd = CanvasCommand(verb: .font, fontDelta: try a.double("delta"))
        if let d = cmd.fontDelta, d == 0 { throw ScriptError("delta must not be 0; leave it out to reset") }
        if let ref = try a.paneRef() { cmd.pane = try lookup(ref).id }
        return try relay(cmd)
    }

    private func showSession(_ a: ScriptArgs) throws -> Any? {
        try needVersion(CanvasVerbProtoVersion, "session")

        guard let name = try a.string("name") else { throw ScriptError("name is required") }

        let known = [LocalHost] + session.world.peers.map(\.name)
        guard known.contains(name) else { throw ScriptError("no such session \(name) (have: \(known.joined(separator: ", ")))") }

        return try relay(CanvasCommand(verb: .session, session: name))
    }

    // A keybind action by name (fit-all, zoom-pane, ...), as if its key was hit.
    private func queue(_ a: ScriptArgs) throws -> Any? {
        guard let name = try a.string("name") else { throw ScriptError("an action name is required") }

        let extra = ScriptArgs(raw: a.raw["args"] as? [String: Any] ?? a.raw)
        var cmd = CanvasCommand(verb: .action, action: name, duration: try extra.double("dur"))
        if let ref = try extra.paneRef() { cmd.pane = try lookup(ref).id }
        return try relay(cmd)
    }

    // Keys typed on the canvas: "cmd+d", or a sequence "ctrl+b>c". Bound keys
    // run, the rest fall away.
    private func press(_ a: ScriptArgs) throws -> Any? {
        guard let keys = try a.string("keys") else { throw ScriptError("keys are required, like cmd+d or ctrl+b>c") }
        guard KeySequence(keys) != nil else { throw ScriptError("bad key \"\(keys)\"") }

        return try relay(CanvasCommand(verb: .press, keys: keys))
    }

    // The escape hatch: any frame a client may send, by its MsgTag name
    // ("createPane", "reportEvent", ...), with a JSON body. Nothing checks it
    // for you; the daemon's answer comes back as ordinary events.
    private func call(_ a: ScriptArgs) throws -> Any? {
        guard let method = try a.string("method") else { throw ScriptError("a method name is required") }
        guard let tag = (1..<MsgTag.firstReply).compactMap({ MsgTag(rawValue: $0) }).first(where: { "\($0)" == method }) else {
            throw ScriptError("no such method \(method)")
        }

        let body = a.raw["args"] as? [String: Any] ?? [:]
        let json = Data(try ScriptJSON.encode(body).utf8)
        try loop.act { try self.session.sendRaw(tag, json: json) }
        return [:] as [String: Any]
    }
}
