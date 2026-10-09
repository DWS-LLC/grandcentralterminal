// UI-side connection to gctd. All delegate callbacks arrive on main.

import Foundation
import Common

protocol CanvasConnDelegate: AnyObject {
    func connWelcome(_ panes: [PaneMeta], _ groups: [GroupMeta])
    func connPaneCreated(_ meta: PaneMeta)
    func connPaneMeta(_ meta: PaneMeta)
    func connOutput(_ id: PaneID, _ data: Data)
    func connPaneExit(_ id: PaneID, _ code: Int32)
    func connGroupCreated(_ meta: GroupMeta)
    func connGroupMeta(_ meta: GroupMeta)
    func connGroupExit(_ id: GroupID)
    func connClosed()
}

final class CanvasConn: @unchecked Sendable {
    weak var delegate: CanvasConnDelegate?
    private let conn: Conn

    init?(sockPath: String) {
        let fd = connectUnixSocket(sockPath)
        guard fd >= 0 else { return nil }
        conn = Conn(fd: fd)
    }

    func start() {
        _ = conn.send(tag: .hello, json: Hello(version: ProtoVersion))
        Thread(block: { [weak self] in
            guard let self else { return }
            self.conn.readLoop { frame in
                DispatchQueue.main.async {
                    self.handle(frame)
                }
            }
            DispatchQueue.main.async { self.delegate?.connClosed() }
        }).start()
    }

    private func handle(_ frame: Frame) {
        switch frame.tag {
        case .welcome, .paneList:
            if let w: Welcome = frame.decode() {
                delegate?.connWelcome(w.panes, w.groups)
            }
        case .paneCreated:
            if let m: PaneCreated = frame.decode() { delegate?.connPaneCreated(m.meta) }
        case .paneMeta:
            if let m: PaneMeta = frame.decode() { delegate?.connPaneMeta(m) }
        case .outputPane:
            if let id = frame.paneID { delegate?.connOutput(id, frame.data) }
        case .paneExit:
            if let e: PaneExit = frame.decode() { delegate?.connPaneExit(e.id, e.code) }
        case .groupCreated:
            if let m: GroupCreated = frame.decode() { delegate?.connGroupCreated(m.meta) }
        case .groupMeta:
            if let m: GroupMeta = frame.decode() { delegate?.connGroupMeta(m) }
        case .groupExit:
            if let e: GroupRef = frame.decode() { delegate?.connGroupExit(e.id) }
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
