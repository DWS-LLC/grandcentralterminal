// Shared wire protocol between gctd (daemon) and the terminal app.
//
// Framing: 4-byte big-endian length, then payload. Payload starts with a
// one-byte MsgTag. Control messages are UTF-8 JSON; data messages carry a
// 16-byte pane id followed by raw bytes.

import Foundation

public let ProtoVersion: UInt16 = 1

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

    // daemon -> client
    case welcome     = 64 // JSON Welcome
    case paneCreated = 65 // JSON PaneCreated
    case paneMeta    = 66 // JSON PaneMeta (updates: name/cwd/title/exited)
    case outputPane  = 67 // data: uuid + bytes
    case paneExit    = 68 // JSON PaneExit
    case paneList    = 69 // JSON Welcome (same shape)
    case errorReply  = 70 // JSON ErrorReply
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
    public init(version: UInt16 = ProtoVersion) { self.version = version }
}

public struct CreatePane: Codable, Sendable {
    public var rect: Rect
    public var cwd: String?
    public var name: String?
    public var command: String?   // e.g. "ssh host" for remote panes; nil = default shell
    public init(rect: Rect, cwd: String? = nil, name: String? = nil, command: String? = nil) {
        self.rect = rect; self.cwd = cwd; self.name = name; self.command = command
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
    public init(id: PaneID, rect: Rect, allowOverlap: Bool = false) {
        self.id = id; self.rect = rect; self.allowOverlap = allowOverlap
    }
    enum CodingKeys: String, CodingKey { case id, rect, allowOverlap }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PaneID.self, forKey: .id)
        rect = try c.decode(Rect.self, forKey: .rect)
        allowOverlap = try c.decodeIfPresent(Bool.self, forKey: .allowOverlap) ?? false
    }
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
    public init(id: PaneID, rect: Rect, name: String?, cwd: String, host: String,
                title: String?, exited: Bool) {
        self.id = id; self.rect = rect; self.name = name; self.cwd = cwd
        self.host = host; self.title = title; self.exited = exited
    }
}

public struct Welcome: Codable, Sendable {
    public var version: UInt16
    public var panes: [PaneMeta]
    public init(version: UInt16 = ProtoVersion, panes: [PaneMeta]) {
        self.version = version; self.panes = panes
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
