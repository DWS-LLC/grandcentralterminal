// HostHub: one CanvasConn per daemon (local unix + TCP remotes).
//
// The canvas keeps a single pane namespace, but PaneIDs are only unique
// per daemon — two daemons mint colliding UUIDs freely. So the hub maps
// every remote (owner, PaneID) pair to a stable local PaneID, and tags
// each pane's host field with the owner label ("local" or the config
// [host.<name>]). Groups are same-owner only: group ids are likewise
// namespaced per owner, and cross-owner membership is refused canvas-side.
//
// All CanvasView call sites keep using `conn?....`; the hub routes each
// request to the owning connection by pane/group id.

import Foundation
import Common

final class HostHub {
    weak var view: CanvasView?

    // Owner -> live connection. "local" is the unix socket.
    private var conns = [String: CanvasConn]()

    // (owner, remote PaneID) -> local PaneID. Stable for the session:
    // the canvas never reuses a local id once mapped.
    private var paneMap = [String: [PaneID: PaneID]]()
    private var paneOwner = [PaneID: String]()
    // Reverse: local PaneID -> remote PaneID (for outbound requests).
    private var paneRemote = [PaneID: PaneID]()

    // Same for groups: (owner, remote GroupID) <-> local GroupID.
    private var groupMap = [String: [GroupID: GroupID]]()
    private var groupOwner = [GroupID: String]()
    private var groupRemote = [GroupID: GroupID]()

    // MARK: - Connections

    /// Local unix connection. Nil when the daemon isn't reachable.
    func connectLocal(sockPath: String, delegate: CanvasConnDelegate) -> Bool {
        guard let c = CanvasConn(sockPath: sockPath, owner: "local") else { return false }
        c.delegate = delegate
        conns["local"] = c
        c.start()
        return true
    }

    /// TCP remote. Nil/false when unreachable or the token is wrong
    /// (CanvasConn's init gates on the welcome).
    func connectRemote(_ h: GCTRemoteHost, delegate: CanvasConnDelegate) -> Bool {
        guard let c = CanvasConn(tcpHost: h.host, port: h.port,
                                 token: h.token, owner: h.name) else { return false }
        c.delegate = delegate
        conns[h.name] = c
        c.start()
        return true
    }

    func disconnect(owner: String) {
        conns.removeValue(forKey: owner)
    }

    func owners() -> [String] { Array(conns.keys).sorted() }

    func conn(forOwner owner: String) -> CanvasConn? { conns[owner] }

    func owner(of id: PaneID) -> String? { paneOwner[id] }

    func groupOwner(of id: GroupID) -> String? { groupOwner[id] }

    // MARK: - Inbound mapping (daemon ids -> canvas ids)

    /// Map a remote pane meta to canvas space: stable local id + tagged host.
    func inboundPane(_ meta: PaneMeta, owner: String) -> PaneMeta {
        var m = meta
        m.id = localPane(remote: meta.id, owner: owner)
        // Tag the host so chrome/switcher read the owner, not "local".
        m.host = owner
        return m
    }

    func inboundGroup(_ meta: GroupMeta, owner: String) -> GroupMeta {
        var g = meta
        let local = localGroup(remote: meta.id, owner: owner)
        g.id = local
        g.members = meta.members.map { localPane(remote: $0, owner: owner) }
        return g
    }

    func localPane(remote: PaneID, owner: String) -> PaneID {
        if let hit = paneMap[owner]?[remote] { return hit }
        let fresh = PaneID()
        paneMap[owner, default: [:]][remote] = fresh
        paneOwner[fresh] = owner
        paneRemote[fresh] = remote
        return fresh
    }

    func localGroup(remote: GroupID, owner: String) -> GroupID {
        if let hit = groupMap[owner]?[remote] { return hit }
        let fresh = GroupID()
        groupMap[owner, default: [:]][remote] = fresh
        groupOwner[fresh] = owner
        groupRemote[fresh] = remote
        return fresh
    }

    /// Translate a canvas group id to the remote id for `owner`
    /// (for CreatePane.joinGroup). Nil when the group isn't owned there.
    func remoteGroupID(_ local: GroupID, owner: String) -> GroupID? {
        guard groupOwner[local] == owner else { return nil }
        return groupRemote[local]
    }

    /// Forget a pane mapping on exit/close (ids never reused mid-session,
    /// but the tables shouldn't grow stale owners forever).
    func forgetPane(_ local: PaneID) {
        guard let owner = paneOwner[local], let remote = paneRemote[local] else { return }
        paneMap[owner]?.removeValue(forKey: remote)
        paneOwner.removeValue(forKey: local)
        paneRemote.removeValue(forKey: local)
    }

    func forgetGroup(_ local: GroupID) {
        guard let owner = groupOwner[local], let remote = groupRemote[local] else { return }
        groupMap[owner]?.removeValue(forKey: remote)
        groupOwner.removeValue(forKey: local)
        groupRemote.removeValue(forKey: local)
    }

    /// Drop every mapping for an owner (reconnect Door: fresh welcome
    /// re-maps; stale panes are removed by the view first).
    func forgetOwner(_ owner: String) {
        for local in paneMap[owner]?.values ?? [:].values {
            paneOwner.removeValue(forKey: local)
            paneRemote.removeValue(forKey: local)
        }
        paneMap.removeValue(forKey: owner)
        for local in groupMap[owner]?.values ?? [:].values {
            groupOwner.removeValue(forKey: local)
            groupRemote.removeValue(forKey: local)
        }
        groupMap.removeValue(forKey: owner)
    }

    // MARK: - Outbound routing (canvas ids -> owning conn + remote ids)

    private func remotePane(_ local: PaneID) -> (CanvasConn, PaneID)? {
        guard let owner = paneOwner[local], let remote = paneRemote[local],
              let c = conns[owner] else { return nil }
        return (c, remote)
    }

    private func remoteGroup(_ local: GroupID) -> (CanvasConn, GroupID)? {
        guard let owner = groupOwner[local], let remote = groupRemote[local],
              let c = conns[owner] else { return nil }
        return (c, remote)
    }

    // Every method mirrors CanvasConn, translated to the owner + remote id.
    // Unknown ids (stale views mid-reconnect) are dropped silently.

    func createPane(_ req: CreatePane, owner: String) {
        conns[owner]?.createPane(req)
    }

    func attachPane(_ req: AttachPane) {
        guard let (c, remote) = remotePane(req.id) else { return }
        c.attachPane(AttachPane(id: remote, cols: req.cols, rows: req.rows))
    }

    func resizePane(_ req: ResizePane) {
        guard let (c, remote) = remotePane(req.id) else { return }
        c.resizePane(ResizePane(id: remote, cols: req.cols, rows: req.rows))
    }

    func closePane(_ id: PaneID) {
        guard let (c, remote) = remotePane(id) else { return }
        c.closePane(remote)
    }

    func renamePane(_ req: RenamePane) {
        guard let (c, remote) = remotePane(req.id) else { return }
        c.renamePane(RenamePane(id: remote, name: req.name))
    }

    func movePane(_ req: MovePane) {
        guard let (c, remote) = remotePane(req.id) else { return }
        c.movePane(MovePane(id: remote, rect: req.rect, allowOverlap: req.allowOverlap))
    }

    func paneCwd(_ req: PaneCwd) {
        guard let (c, remote) = remotePane(req.id) else { return }
        c.paneCwd(PaneCwd(id: remote, cwd: req.cwd))
    }

    func setFloating(_ req: SetFloating) {
        guard let (c, remote) = remotePane(req.id) else { return }
        c.setFloating(SetFloating(id: remote, floating: req.floating,
                                  allowOverlap: req.allowOverlap))
    }

    func sendInput(_ id: PaneID, _ data: Data) {
        guard let (c, remote) = remotePane(id) else { return }
        c.sendInput(remote, data)
    }

    /// Groups are same-owner only: refuse mixed membership canvas-side
    /// (the daemons each own disjoint layout worlds; a cross-host group
    /// would arbitrate against half its members on each side).
    func createGroup(_ req: CreateGroup, owner: String) -> GroupID? {
        guard let c = conns[owner] else { return nil }
        let remotes = req.members.compactMap { local -> PaneID? in
            guard paneOwner[local] == owner else { return nil }
            return paneRemote[local]
        }
        guard remotes.count == req.members.count, remotes.count >= 1 else { return nil }
        c.createGroup(CreateGroup(name: req.name, color: req.color, members: remotes))
        return nil // id arrives via groupCreated broadcast (mapped inbound)
    }

    func updateGroup(_ req: UpdateGroup) {
        guard let (c, remote) = remoteGroup(req.id) else { return }
        let owner = groupOwner[req.id]
        let remotes = req.members.compactMap { local -> PaneID? in
            guard paneOwner[local] == owner else { return nil }
            return paneRemote[local]
        }
        guard remotes.count == req.members.count else { return }
        c.updateGroup(UpdateGroup(id: remote, name: req.name,
                                  color: req.color, members: remotes))
    }

    func deleteGroup(_ id: GroupID) {
        guard let (c, remote) = remoteGroup(id) else { return }
        c.deleteGroup(remote)
    }

    func moveGroup(_ req: MoveGroup) {
        guard let (c, remote) = remoteGroup(req.id) else { return }
        c.moveGroup(MoveGroup(id: remote, dx: req.dx, dy: req.dy,
                              allowOverlap: req.allowOverlap))
    }
}
