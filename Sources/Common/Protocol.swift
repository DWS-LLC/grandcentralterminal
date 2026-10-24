// Shared wire protocol between gctd (daemon) and the terminal app.
//
// Framing: 4-byte big-endian length, then payload. Payload starts with a
// one-byte MsgTag. Control messages are UTF-8 JSON; data messages carry a
// 16-byte pane id followed by raw bytes.

import Foundation

public let ProtoVersion: UInt16 = 3
// First protocol revision whose daemon understands MsgTag.arrangePanes.
public let ArrangeProtoVersion: UInt16 = 2
// First protocol revision whose daemon understands MsgTag.layoutPolicy.
public let LayoutProtoVersion: UInt16 = 3

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
    public init(version: UInt16 = ProtoVersion, token: String? = nil) {
        self.version = version; self.token = token
    }
    enum CodingKeys: String, CodingKey { case version, token }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(UInt16.self, forKey: .version) ?? ProtoVersion
        token = try c.decodeIfPresent(String.self, forKey: .token)
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
    // Agent spawn: land in the free air around this pane (Orbit),
    // pushed away from the rest. rect only supplies the size. Ignored
    // with joinGroup. Decodes missing (old clients) as nil.
    public var orbitAround: PaneID?
    public init(rect: Rect, cwd: String? = nil, name: String? = nil,
                command: String? = nil, allowOverlap: Bool = false, gap: Double = 0,
                joinGroup: GroupID? = nil, joinDirection: String? = nil,
                orbitAround: PaneID? = nil) {
        self.rect = rect; self.cwd = cwd; self.name = name
        self.command = command; self.allowOverlap = allowOverlap; self.gap = gap
        self.joinGroup = joinGroup; self.joinDirection = joinDirection
        self.orbitAround = orbitAround
    }
    enum CodingKeys: String, CodingKey {
        case rect, cwd, name, command, allowOverlap, gap, joinGroup, joinDirection
        case orbitAround
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
        orbitAround = try c.decodeIfPresent(PaneID.self, forKey: .orbitAround)
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
    public var name: String?      // user-set name; nil -> "Terminal"
    public var cwd: String
    public var host: String       // "local" or hostname
    public var title: String?     // program-set title (OSC)
    public var exited: Bool
    // Floating: ignores same-group/ungrouped overlap (still hard-blocked
    // by foreign group bounds). Decodes missing (old daemons) as false.
    public var floating: Bool
    public init(id: PaneID, rect: Rect, name: String?, cwd: String, host: String,
                title: String?, exited: Bool, floating: Bool = false) {
        self.id = id; self.rect = rect; self.name = name; self.cwd = cwd
        self.host = host; self.title = title; self.exited = exited
        self.floating = floating
    }
    enum CodingKeys: String, CodingKey {
        case id, rect, name, cwd, host, title, exited, floating
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
    }
}

public struct Welcome: Codable, Sendable {
    public var version: UInt16
    public var panes: [PaneMeta]
    // Absent on the wire from old daemons; decode as empty.
    public var groups: [GroupMeta]
    public init(version: UInt16 = ProtoVersion, panes: [PaneMeta],
                groups: [GroupMeta] = []) {
        self.version = version; self.panes = panes; self.groups = groups
    }
    enum CodingKeys: String, CodingKey { case version, panes, groups }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(UInt16.self, forKey: .version) ?? ProtoVersion
        panes = try c.decodeIfPresent([PaneMeta].self, forKey: .panes) ?? []
        groups = try c.decodeIfPresent([GroupMeta].self, forKey: .groups) ?? []
    }
}

public struct PaneCreated: Codable, Sendable {
    public var meta: PaneMeta
    public init(meta: PaneMeta) { self.meta = meta }
}

public struct PaneExit: Codable, Sendable {
    public var id: PaneID
    public var code: Int32
    public init(id: PaneID, code: Int32) { self.id = id; self.code = code }
}

public struct ErrorReply: Codable, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
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
    public init(name: String? = nil, color: String? = nil,
                members: [PaneID] = []) {
        self.name = name; self.color = color; self.members = members
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
    public init(meta: GroupMeta) { self.meta = meta }
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
