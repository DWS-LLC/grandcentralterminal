// Shared wire protocol between gctd (daemon) and the terminal app.
//
// Framing: 4-byte big-endian length, then payload. Payload starts with a
// one-byte MsgTag. Control messages are UTF-8 JSON; data messages carry a
// 16-byte pane id followed by raw bytes.

import Foundation

public let ProtoVersion: UInt16 = 7
// First protocol revision whose daemon understands MsgTag.arrangePanes.
public let ArrangeProtoVersion: UInt16 = 2
// First protocol revision whose daemon understands MsgTag.layoutPolicy.
public let LayoutProtoVersion: UInt16 = 3
// First protocol revision whose daemon keeps cable ties (MsgTag.setTie).
public let TieProtoVersion: UInt16 = 4
// First protocol revision whose daemon echoes create reqIDs.
public let ReqIDProtoVersion: UInt16 = 5
// First protocol revision whose daemon hosts guest panes for peer daemons.
public let PeerProtoVersion: UInt16 = 6
// First protocol revision whose paneExit carries the real exit status and
// whose daemon answers MsgTag.waitPane.
public let WaitProtoVersion: UInt16 = 7

// PaneExit.code of a pane whose status nobody collected.
public let ExitUnknown: Int32 = -1

// PaneMeta.host of a pane whose pty runs on the daemon holding it.
public let LocalHost = "local"

public enum MsgTag: UInt8 {
    // client -> daemon
    case hello       = 1  // JSON Hello
    case createPane  = 2  // JSON CreatePane
    case attachPane  = 3  // JSON AttachPane
    case inputPane   = 4  // data: uuid + bytes
    case resizePane  = 5  // JSON ResizePane
    case detachPane  = 6  // JSON PaneRef
    case closePane   = 7  // JSON PaneRef
    case renamePane  = 8  // JSON RenamePane
    case listPanes   = 9  // no payload
    case killDaemon  = 10 // no payload
    case movePane    = 11 // JSON MovePane
    case paneCwd     = 12 // JSON PaneCwd
    case createGroup = 13 // JSON CreateGroup
    case updateGroup = 14 // JSON UpdateGroup
    case deleteGroup = 15 // JSON GroupRef
    case moveGroup   = 16 // JSON MoveGroup
    case setFloating = 17 // JSON SetFloating
    case dumpPane    = 18 // JSON DumpPane (read-only ring snapshot)
    case focusPane   = 19 // JSON PaneRef (agent asks canvas to focus)
    case canvasCommand = 20 // JSON CanvasCommand (scripted camera/action)
    case arrangePanes = 21 // JSON ArrangePanes (exact batch placement)
    case layoutPolicy = 22 // JSON LayoutPolicy (canvas config for headless clients)
    case notifyPane  = 23 // JSON PaneNotify (agent asks canvas to notify)
    case setTie      = 24 // JSON TieMeta (create or update a cable tie)
    case removeTie   = 25 // JSON TieRef
    case claimGuests = 26 // JSON GuestClaim (peer -> host: the guests it keeps)
    case peerRetry   = 27 // JSON PeerRef (canvas -> daemon: dial that host now)
    case waitPane    = 28 // JSON PaneRef (reply: paneExit now if it already ended)

    // daemon -> client
    case welcome     = 64 // JSON Welcome
    case paneCreated = 65 // JSON PaneCreated
    case paneMeta    = 66 // JSON PaneMeta (updates: name/cwd/title/exited)
    case outputPane  = 67 // data: uuid + bytes
    case paneExit    = 68 // JSON PaneExit
    case paneList    = 69 // JSON Welcome (same shape)
    case errorReply  = 70 // JSON ErrorReply
    case groupCreated  = 71 // JSON GroupCreated
    case groupMeta     = 72 // JSON GroupMeta (updates: name/color/members)
    case groupExit     = 73 // JSON GroupRef
    case paneDump      = 74 // JSON PaneDump (reply to dumpPane)
    case paneFocus     = 75 // JSON PaneRef (daemon -> canvas: focus this)
    case canvasRelay   = 76 // JSON CanvasCommand (daemon -> canvas: run this)
    case replayPane    = 77 // data: uuid + ring snapshot (history, not live)
    case paneNotice    = 78 // JSON PaneNotify (daemon -> canvas: post this)
    case tieMeta       = 79 // JSON TieMeta (created or updated)
    case tieExit       = 80 // JSON TieRef
    case peerState     = 81 // JSON PeerInfo (a peer link came up or went down)
}

public struct PaneID: Hashable, Sendable, CustomStringConvertible {
    public let uuid: UUID
    public init(_ uuid: UUID = UUID()) { self.uuid = uuid }
    public init?(string: String) {
        guard let u = UUID(uuidString: string) else { return nil }
        self.uuid = u
    }
    public var description: String { uuid.uuidString }
}

// Flat string on the wire: {"id": "DEADBEEF-..."}.
extension PaneID: Codable {
    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let u = UUID(uuidString: s) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "bad pane id \(s)"))
        }
        self.init(u)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(uuid.uuidString)
    }
}

public struct Rect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public struct Hello: Codable, Sendable {
    public var version: UInt16
    // Auth token for TCP remotes; nil = unix socket (trusted) or no auth.
    // Decodes missing (old peers) as nil; old decoders ignore the key.
    public var token: String?
    // Set by a peer daemon (its stable id): the link hosts guest panes for
    // that owner instead of viewing the session. Nil = a UI/CLI client.
    public var owner: String?
    public init(version: UInt16 = ProtoVersion, token: String? = nil, owner: String? = nil) {
        self.version = version; self.token = token; self.owner = owner
    }
    enum CodingKeys: String, CodingKey { case version, token, owner }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(UInt16.self, forKey: .version) ?? ProtoVersion
        token = try c.decodeIfPresent(String.self, forKey: .token)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
    }
}

public struct CreatePane: Codable, Sendable {
    public var rect: Rect
    public var cwd: String?
    public var name: String?
    public var command: String?   // e.g. "ssh host" for remote panes; nil = default shell
    // Same policy as MovePane; decodes missing (old clients) as false.
    public var allowOverlap: Bool
    // Minimum padding (world points); decodes missing as 0 = flush.
    public var gap: Double
    // Directional split from a grouped pane: admit into this group on
    // create (daemon trials the grown-bounds rule). Nil = groupless.
    // Decodes missing (old clients) as nil.
    public var joinGroup: GroupID?
    // Split axis for joinGroup shove: "left"/"right" push horizontally,
    // "above"/"below" vertically. Nil = no shove (plain admit trial).
    // Decodes missing as nil.
    public var joinDirection: String?
    // The pane this one was spawned from (cables, spring links); a spawn
    // from a caller pane has that caller as parent. Decodes missing as nil.
    public var parent: PaneID?
    // Echoed in PaneCreated so the requester spots its own reply among
    // concurrent creates. Decodes missing as nil.
    public var reqID: String?
    // Peer host to run the pty on ([host.<name>]); the pane still lives in
    // THIS daemon's layout. Nil = a local pty. Decodes missing as nil.
    public var host: String?
    public init(rect: Rect, cwd: String? = nil, name: String? = nil,
                command: String? = nil, allowOverlap: Bool = false, gap: Double = 0,
                joinGroup: GroupID? = nil, joinDirection: String? = nil,
                parent: PaneID? = nil, reqID: String? = nil,
                host: String? = nil) {
        self.rect = rect; self.cwd = cwd; self.name = name
        self.command = command; self.allowOverlap = allowOverlap; self.gap = gap
        self.joinGroup = joinGroup; self.joinDirection = joinDirection
        self.parent = parent; self.reqID = reqID
        self.host = host
    }
    enum CodingKeys: String, CodingKey {
        case rect, cwd, name, command, allowOverlap, gap, joinGroup, joinDirection
        case parent, reqID, host
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rect = try c.decode(Rect.self, forKey: .rect)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        allowOverlap = try c.decodeIfPresent(Bool.self, forKey: .allowOverlap) ?? false
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? 0
        joinGroup = try c.decodeIfPresent(GroupID.self, forKey: .joinGroup)
        joinDirection = try c.decodeIfPresent(String.self, forKey: .joinDirection)
        parent = try c.decodeIfPresent(PaneID.self, forKey: .parent)
        reqID = try c.decodeIfPresent(String.self, forKey: .reqID)
        host = try c.decodeIfPresent(String.self, forKey: .host)
    }
}

public struct AttachPane: Codable, Sendable {
    public var id: PaneID
    public var cols: UInt16
    public var rows: UInt16
    public init(id: PaneID, cols: UInt16, rows: UInt16) {
        self.id = id; self.cols = cols; self.rows = rows
    }
}

public struct ResizePane: Codable, Sendable {
    public var id: PaneID
    public var cols: UInt16
    public var rows: UInt16
    public init(id: PaneID, cols: UInt16, rows: UInt16) {
        self.id = id; self.cols = cols; self.rows = rows
    }
}

public struct PaneRef: Codable, Sendable {
    public var id: PaneID
    public init(id: PaneID) { self.id = id }
}

public struct RenamePane: Codable, Sendable {
    public var id: PaneID
    public var name: String?
    public init(id: PaneID, name: String?) { self.id = id; self.name = name }
}

// A harness's "look at this pane" ping: the canvas posts it as a desktop
// notification that focuses the pane on click.
public struct PaneNotify: Codable, Sendable {
    public var id: PaneID
    public var title: String?
    public var body: String
    public init(id: PaneID, title: String? = nil, body: String) {
        self.id = id; self.title = title; self.body = body
    }
}

public struct MovePane: Codable, Sendable {
    public var id: PaneID
    public var rect: Rect
    // Layout policy: false (default) = daemon resolves against the store
    // so the broadcast stream is overlap-free. True = place exactly.
    // Decodes missing (old clients, scripts) as false.
    public var allowOverlap: Bool
    // Minimum padding (world points) the daemon keeps around the pane.
    // Decodes missing (old clients) as 0 = flush.
    public var gap: Double
    public init(id: PaneID, rect: Rect, allowOverlap: Bool = false, gap: Double = 0) {
        self.id = id; self.rect = rect; self.allowOverlap = allowOverlap; self.gap = gap
    }
    enum CodingKeys: String, CodingKey { case id, rect, allowOverlap, gap }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PaneID.self, forKey: .id)
        rect = try c.decode(Rect.self, forKey: .rect)
        allowOverlap = try c.decodeIfPresent(Bool.self, forKey: .allowOverlap) ?? false
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? 0
    }
}

public struct PaneRect: Codable, Sendable {
    public var id: PaneID
    public var rect: Rect
    public init(id: PaneID, rect: Rect) { self.id = id; self.rect = rect }
}

// Atomic batch placement: the client already solved the layout, so the
// daemon applies every rect as-is (no per-move arbitration, which would
// shove panes around mid-rearrangement).
public struct ArrangePanes: Codable, Sendable {
    public var moves: [PaneRect]
    public init(moves: [PaneRect]) { self.moves = moves }
}

public struct PaneCwd: Codable, Sendable {
    public var id: PaneID
    public var cwd: String
    public init(id: PaneID, cwd: String) { self.id = id; self.cwd = cwd }
}

public struct PaneMeta: Codable, Sendable {
    public var id: PaneID
    public var rect: Rect
    public var name: String?      // user-set name; nil -> auto name (AutoName)
    public var cwd: String
    // "local" = the pty runs on this daemon; else the [host.<name>] peer
    // that runs it for this session (a proxy pane).
    public var host: String
    public var title: String?     // program-set title (OSC)
    public var exited: Bool
    // Floating: ignores same-group/ungrouped overlap (still hard-blocked
    // by foreign group bounds). Decodes missing (old daemons) as false.
    public var floating: Bool
    // Daemon-observed context that feeds auto names and the spring layout.
    // All decode missing (old daemons) as nil.
    public var proc: String?      // foreground command line ("nvim a.swift"); nil = idle shell
    public var repoRoot: String?  // git work tree containing cwd
    public var worktree: String?  // branch, only for a linked worktree
    public var parent: PaneID?    // pane that spawned this one (gctd open)
    // Guest pane: a pty hosted for the peer daemon with this id; it has no
    // place in this daemon's own layout. Decodes missing as nil.
    public var guestOf: String?
    // Proxy pane whose peer link is down: kept in the layout, input dropped.
    public var offline: Bool
    public init(id: PaneID, rect: Rect, name: String?, cwd: String, host: String,
                title: String?, exited: Bool, floating: Bool = false) {
        self.id = id; self.rect = rect; self.name = name; self.cwd = cwd
        self.host = host; self.title = title; self.exited = exited
        self.floating = floating
        self.offline = false
    }
    enum CodingKeys: String, CodingKey {
        case id, rect, name, cwd, host, title, exited, floating
        case proc, repoRoot, worktree, parent, guestOf, offline
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PaneID.self, forKey: .id)
        rect = try c.decode(Rect.self, forKey: .rect)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? NSHomeDirectory()
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "local"
        title = try c.decodeIfPresent(String.self, forKey: .title)
        exited = try c.decodeIfPresent(Bool.self, forKey: .exited) ?? false
        floating = try c.decodeIfPresent(Bool.self, forKey: .floating) ?? false
        proc = try c.decodeIfPresent(String.self, forKey: .proc)
        repoRoot = try c.decodeIfPresent(String.self, forKey: .repoRoot)
        worktree = try c.decodeIfPresent(String.self, forKey: .worktree)
        parent = try c.decodeIfPresent(PaneID.self, forKey: .parent)
        guestOf = try c.decodeIfPresent(String.self, forKey: .guestOf)
        offline = try c.decodeIfPresent(Bool.self, forKey: .offline) ?? false
    }
}

// A tie on cables between spawned panes: the strands it bundles (each a
// parent -> child cable, named by its two panes) and where along the cable
// it sits (0...1). `delta` is a strand's grip offset, in cable sample points.
public struct TieMeta: Codable, Sendable, Equatable {
    public struct Strand: Codable, Sendable, Equatable {
        public var parent: PaneID
        public var child: PaneID
        public var delta: Double
        public init(parent: PaneID, child: PaneID, delta: Double = 0) {
            self.parent = parent; self.child = child; self.delta = delta
        }
    }

    public var id: String
    public var s: Double
    public var strands: [Strand]
    public init(id: String = UUID().uuidString, s: Double, strands: [Strand]) {
        self.id = id; self.s = s; self.strands = strands
    }
}

public struct TieRef: Codable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}

public struct Welcome: Codable, Sendable {
    public var version: UInt16
    public var panes: [PaneMeta]
    // Absent on the wire from old daemons; decode as empty.
    public var groups: [GroupMeta]
    public var ties: [TieMeta]
    // Guest panes this daemon hosts for peers (a UI client sees all of them,
    // a peer link only its own). Never part of `panes`.
    public var guests: [PaneMeta]
    // Configured peer hosts and whether their link is up.
    public var peers: [PeerInfo]
    public init(version: UInt16 = ProtoVersion, panes: [PaneMeta],
                groups: [GroupMeta] = [], ties: [TieMeta] = [],
                guests: [PaneMeta] = [], peers: [PeerInfo] = []) {
        self.version = version; self.panes = panes; self.groups = groups
        self.ties = ties; self.guests = guests; self.peers = peers
    }
    enum CodingKeys: String, CodingKey { case version, panes, groups, ties, guests, peers }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(UInt16.self, forKey: .version) ?? ProtoVersion
        panes = try c.decodeIfPresent([PaneMeta].self, forKey: .panes) ?? []
        groups = try c.decodeIfPresent([GroupMeta].self, forKey: .groups) ?? []
        ties = try c.decodeIfPresent([TieMeta].self, forKey: .ties) ?? []
        guests = try c.decodeIfPresent([PaneMeta].self, forKey: .guests) ?? []
        peers = try c.decodeIfPresent([PeerInfo].self, forKey: .peers) ?? []
    }
}

// A configured peer host and the state of this daemon's link to it.
public struct PeerInfo: Codable, Sendable, Equatable {
    public var name: String
    public var up: Bool
    public init(name: String, up: Bool) { self.name = name; self.up = up }
}

public struct PeerRef: Codable, Sendable {
    public var name: String
    public init(name: String) { self.name = name }
}

// The guest ids a peer daemon still has proxies for. The host reaps every
// other guest of that owner (crash or close-while-down leftovers).
public struct GuestClaim: Codable, Sendable {
    public var ids: [PaneID]
    public init(ids: [PaneID]) { self.ids = ids }
}

public struct PaneCreated: Codable, Sendable {
    public var meta: PaneMeta
    public var reqID: String?  // CreatePane.reqID, nil for other creators
    public init(meta: PaneMeta, reqID: String? = nil) { self.meta = meta; self.reqID = reqID }
}

public struct PaneExit: Codable, Sendable {
    public var id: PaneID
    // Shell-style status (128+signal when killed); ExitUnknown when the
    // daemon never saw one (closed by a client, or no waitpid result).
    public var code: Int32
    public init(id: PaneID, code: Int32) { self.id = id; self.code = code }
}

public struct ErrorReply: Codable, Sendable {
    public var message: String
    // CreatePane.reqID this refuses; nil for every other failure.
    public var reqID: String?
    public init(message: String, reqID: String? = nil) {
        self.message = message; self.reqID = reqID
    }
}

// MARK: - Terminal groups
//
// A group is a named, colored set of panes with a background rectangle
// derived from the union bounds of its members (see GroupGeometry). The
// daemon owns membership: it persists groups, broadcasts changes, prunes
// dead members, and arbitrates layout so panes outside a group can never
// overlap its rectangle, regardless of allowOverlap.

public struct GroupID: Hashable, Sendable, CustomStringConvertible {
    public let uuid: UUID
    public init(_ uuid: UUID = UUID()) { self.uuid = uuid }
    public init?(string: String) {
        guard let u = UUID(uuidString: string) else { return nil }
        self.uuid = u
    }
    public var description: String { uuid.uuidString }
}

// Flat string on the wire, same as PaneID.
extension GroupID: Codable {
    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let u = UUID(uuidString: s) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "bad group id \(s)"))
        }
        self.init(u)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(uuid.uuidString)
    }
}

public struct GroupMeta: Codable, Sendable {
    public var id: GroupID
    public var name: String?
    public var color: String?      // hex like "#3b82f6" or "palette:4"; nil = auto (hash of name)
    public var members: [PaneID]
    public init(id: GroupID, name: String? = nil, color: String? = nil,
                members: [PaneID] = []) {
        self.id = id; self.name = name; self.color = color
        self.members = members
    }
}

public struct CreateGroup: Codable, Sendable {
    public var name: String?
    public var color: String?
    public var members: [PaneID]
    public var reqID: String?  // echoed in GroupCreated; see CreatePane
    public init(name: String? = nil, color: String? = nil,
                members: [PaneID] = [], reqID: String? = nil) {
        self.name = name; self.color = color; self.members = members; self.reqID = reqID
    }
}

// Full replacement: name, color, and member list.
public struct UpdateGroup: Codable, Sendable {
    public var id: GroupID
    public var name: String?
    public var color: String?
    public var members: [PaneID]
    public init(id: GroupID, name: String? = nil, color: String? = nil,
                members: [PaneID] = []) {
        self.id = id; self.name = name; self.color = color
        self.members = members
    }
}

// Rigid group move: every member shifts by (dx, dy), resolved as one
// block so relative offsets survive collision handling.
public struct MoveGroup: Codable, Sendable {
    public var id: GroupID
    public var dx: Double
    public var dy: Double
    // Same policy as MovePane; decodes missing (old clients) as false.
    public var allowOverlap: Bool
    // Minimum padding (world points); decodes missing as 0 = flush.
    public var gap: Double
    public init(id: GroupID, dx: Double, dy: Double,
                allowOverlap: Bool = false, gap: Double = 0) {
        self.id = id; self.dx = dx; self.dy = dy
        self.allowOverlap = allowOverlap; self.gap = gap
    }
    enum CodingKeys: String, CodingKey { case id, dx, dy, allowOverlap, gap }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(GroupID.self, forKey: .id)
        dx = try c.decode(Double.self, forKey: .dx)
        dy = try c.decode(Double.self, forKey: .dy)
        allowOverlap = try c.decodeIfPresent(Bool.self, forKey: .allowOverlap) ?? false
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? 0
    }
}

public struct GroupRef: Codable, Sendable {
    public var id: GroupID
    public init(id: GroupID) { self.id = id }
}

public struct GroupCreated: Codable, Sendable {
    public var meta: GroupMeta
    public var reqID: String?  // CreateGroup.reqID, nil for other creators
    public init(meta: GroupMeta, reqID: String? = nil) { self.meta = meta; self.reqID = reqID }
}

public struct SetFloating: Codable, Sendable {
    public var id: PaneID
    public var floating: Bool
    // Re-tiling policy: false = daemon resolves the pane out of overlap
    // when un-floating. Decodes missing as false.
    public var allowOverlap: Bool
    // Minimum padding (world points); decodes missing as 0 = flush.
    public var gap: Double
    public init(id: PaneID, floating: Bool, allowOverlap: Bool = false, gap: Double = 0) {
        self.id = id; self.floating = floating; self.allowOverlap = allowOverlap; self.gap = gap
    }
    enum CodingKeys: String, CodingKey { case id, floating, allowOverlap, gap }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PaneID.self, forKey: .id)
        floating = try c.decode(Bool.self, forKey: .floating)
        allowOverlap = try c.decodeIfPresent(Bool.self, forKey: .allowOverlap) ?? false
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? 0
    }
}

// Read-only scrollback snapshot: the last `limit` bytes of the pane's ring
// (`limit` <= 0 = whole ring, capped at the ring size). `stripANSI` is a
// requester-side hint; the daemon always ships raw VT (it must not
// interpret the stream — the CLI/scrubber owns that).
public struct DumpPane: Codable, Sendable {
    public var id: PaneID
    public var limit: Int
    public var stripANSI: Bool
    public init(id: PaneID, limit: Int = 0, stripANSI: Bool = false) {
        self.id = id; self.limit = limit; self.stripANSI = stripANSI
    }
}

public struct PaneDump: Codable, Sendable {
    public var id: PaneID
    public var bytes: Int       // bytes actually returned
    public var truncated: Bool  // ring held more than `limit` asked for
    public var dropped: UInt64  // ring bytes evicted before this snapshot
    public var data: String     // raw VT (base64 when not clean UTF-8)
    public var base64: Bool
    public init(id: PaneID, bytes: Int, truncated: Bool, dropped: UInt64,
                data: String, base64: Bool) {
        self.id = id; self.bytes = bytes; self.truncated = truncated
        self.dropped = dropped; self.data = data; self.base64 = base64
    }
}

// MARK: - Scripted canvas control
//
// `gctd camera` / `gctd do`: the daemon validates the pane and relays the
// command to every canvas untouched. The canvas runs it exactly like the
// matching gesture or keybind, so scripted demos show the real behavior.

public enum CanvasVerb: String, Codable, Sendable {
    case camera // animate to (x, y, zoom) or a pane's center
    case action // run a keybind action by name, e.g. "fit-all"
}

public struct CanvasCommand: Codable, Sendable {
    public var verb: CanvasVerb
    public var pane: PaneID?      // camera target / focus before action
    public var action: String?    // GCTAction raw value for .action
    public var x: Double?         // camera world center; nil = keep
    public var y: Double?
    public var zoom: Double?      // camera scale; nil = keep
    public var duration: Double?  // seconds; nil = config default
    public init(verb: CanvasVerb, pane: PaneID? = nil, action: String? = nil,
                x: Double? = nil, y: Double? = nil, zoom: Double? = nil,
                duration: Double? = nil) {
        self.verb = verb; self.pane = pane; self.action = action
        self.x = x; self.y = y; self.zoom = zoom; self.duration = duration
    }
}

// MARK: - Layout policy
//
// The canvas owns window-gap (config.toml); the CLI never reads it. The
// canvas pushes it on connect and reload, and the daemon applies it as
// the floor for every placement, so `gctd open` keeps the same air.

public struct LayoutPolicy: Codable, Sendable {
    public var gap: Double
    // Group title headroom (GroupGeometry.titleClearance); nil from
    // canvases that predate it.
    public var titleClearance: Double?
    public init(gap: Double, titleClearance: Double? = nil) {
        self.gap = gap; self.titleClearance = titleClearance
    }
}
