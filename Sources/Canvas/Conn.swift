// UI-side connection to gctd. All delegate callbacks arrive on main.

import Foundation
import Common

/// Live pty bytes vs the daemon's ring snapshot sent on attach.
enum OutputSource {
    case live, replay
}

protocol CanvasConnDelegate: AnyObject {
    func connWelcome(_ panes: [PaneMeta], _ groups: [GroupMeta], owner: String)
    func connPaneCreated(_ meta: PaneMeta, owner: String)
    func connPaneMeta(_ meta: PaneMeta, owner: String)
    func connOutput(_ id: PaneID, _ data: Data, source: OutputSource, owner: String)
    func connPaneExit(_ id: PaneID, _ code: Int32, owner: String)
    func connGroupCreated(_ meta: GroupMeta, owner: String)
    func connGroupMeta(_ meta: GroupMeta, owner: String)
    func connGroupExit(_ id: GroupID, owner: String)
    func connFocusPane(_ id: PaneID, owner: String)
    func connCanvasCommand(_ cmd: CanvasCommand, owner: String)
    func connClosed(owner: String)
}

final class CanvasConn: @unchecked Sendable {
    weak var delegate: CanvasConnDelegate?
    private let conn: Conn
    // Owner label for pane routing ("local" or the remote host name).
    // The hub tags every inbound meta with it; see HostHub.
    let owner: String
    // Daemon protocol revision, learned from its welcome (old daemons: 1).
    private var peerVersion: UInt16 = 1

    init?(sockPath: String, owner: String = "local") {
        let fd = connectUnixSocket(sockPath)
        guard fd >= 0 else { return nil }
        conn = Conn(fd: fd)
        self.owner = owner
    }

    init?(tcpHost: String, port: UInt16, token: String, owner: String) {
        let fd = connectTCP(host: tcpHost, port: port)
        guard fd >= 0 else { return nil }
        conn = Conn(fd: fd)
        self.owner = owner
        _ = conn.send(tag: .hello, json: Hello(token: token.isEmpty ? nil : token))
        // Gate early: a bad token gets errorReply, never a welcome.
        // Don't block long — the read thread reports connClosed on drop.
        if let first = conn.readFrame() {
            guard first.tag == .welcome || first.tag == .paneList,
                  let _: Welcome = first.decode() else { return nil }
            pendingWelcome = first
        }
    }

    // First frame already consumed by the TCP gate above; start() emits
    // it before entering the read loop.
    private var pendingWelcome: Frame?

    // Silence the delegate first: the read thread's EOF would otherwise
    // report connClosed for an owner that may already have a fresh conn.
    func close() {
        delegate = nil
        conn.close()
    }

    func start() {
        _ = conn.send(tag: .hello, json: Hello(version: ProtoVersion))
        Thread(block: { [weak self] in
            guard let self else { return }
            if let first = self.pendingWelcome {
                self.pendingWelcome = nil
                let f = first
                DispatchQueue.main.async { self.handle(f) }
            }
            self.conn.readLoop { frame in
                DispatchQueue.main.async {
                    self.handle(frame)
                }
            }
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.delegate?.connClosed(owner: self.owner) }
        }).start()
    }

    private func handle(_ frame: Frame) {
        switch frame.tag {
        case .welcome, .paneList:
            if let w: Welcome = frame.decode() {
                peerVersion = w.version
                delegate?.connWelcome(w.panes, w.groups, owner: owner)
            }
        case .paneCreated:
            if let m: PaneCreated = frame.decode() { delegate?.connPaneCreated(m.meta, owner: owner) }
        case .paneMeta:
            if let m: PaneMeta = frame.decode() { delegate?.connPaneMeta(m, owner: owner) }
        case .outputPane:
            if let id = frame.paneID { delegate?.connOutput(id, frame.data, source: .live, owner: owner) }
        case .replayPane:
            if let id = frame.paneID { delegate?.connOutput(id, frame.data, source: .replay, owner: owner) }
        case .paneExit:
            if let e: PaneExit = frame.decode() { delegate?.connPaneExit(e.id, e.code, owner: owner) }
        case .groupCreated:
            if let m: GroupCreated = frame.decode() { delegate?.connGroupCreated(m.meta, owner: owner) }
        case .groupMeta:
            if let m: GroupMeta = frame.decode() { delegate?.connGroupMeta(m, owner: owner) }
        case .groupExit:
            if let e: GroupRef = frame.decode() { delegate?.connGroupExit(e.id, owner: owner) }
        case .paneDump:
            break // agent-CLI only; the canvas never requests dumps
        case .paneFocus:
            if let r: PaneRef = frame.decode() { delegate?.connFocusPane(r.id, owner: owner) }
        case .canvasRelay:
            if let c: CanvasCommand = frame.decode() { delegate?.connCanvasCommand(c, owner: owner) }
        default:
            break
        }
    }

    func createPane(_ req: CreatePane) { conn.send(tag: .createPane, json: req) }
    func attachPane(_ req: AttachPane) { conn.send(tag: .attachPane, json: req) }
    func resizePane(_ req: ResizePane) { conn.send(tag: .resizePane, json: req) }
    func closePane(_ id: PaneID) { conn.send(tag: .closePane, json: PaneRef(id: id)) }
    func renamePane(_ req: RenamePane) { conn.send(tag: .renamePane, json: req) }
    func movePane(_ req: MovePane) { conn.send(tag: .movePane, json: req) }
    // An old daemon drops the connection on an unknown tag, so it gets one
    // movePane per pane instead.
    func arrangePanes(_ req: ArrangePanes) {
        guard peerVersion >= ArrangeProtoVersion else {
            for m in req.moves {
                movePane(MovePane(id: m.id, rect: m.rect, allowOverlap: true, gap: 0))
            }
            return
        }
        conn.send(tag: .arrangePanes, json: req)
    }
    func paneCwd(_ req: PaneCwd) { conn.send(tag: .paneCwd, json: req) }
    func setFloating(_ req: SetFloating) { conn.send(tag: .setFloating, json: req) }
    func sendInput(_ id: PaneID, _ data: Data) {
        conn.sendData(tag: .inputPane, paneID: id, data: data)
    }
    func createGroup(_ req: CreateGroup) { conn.send(tag: .createGroup, json: req) }
    func updateGroup(_ req: UpdateGroup) { conn.send(tag: .updateGroup, json: req) }
    func deleteGroup(_ id: GroupID) { conn.send(tag: .deleteGroup, json: GroupRef(id: id)) }
    func moveGroup(_ req: MoveGroup) { conn.send(tag: .moveGroup, json: req) }
}
