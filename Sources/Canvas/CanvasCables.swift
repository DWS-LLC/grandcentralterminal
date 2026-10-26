// Cables between a pane and the panes it spawned.
//
//   pane.meta.parent ──► edges (world rects) ──► CableSim ──► CableView
//                                                  ▲
//   drag across cables: tie them together          │ ties slide along the
//   drag a tie: slide it     double-click: remove ─┘ cable, never overlap
//
// A 60 Hz tick keeps the sim fed and renders only while something moves.
// Ties live for the session (pane ids are per-session on the canvas).

import AppKit
import Common

// What the last render saw, so a still canvas costs a few comparisons.
final class CableMemo {
    var edges = [CableKey: CableSim.Edge]()
    var tints = [CableKey: CableTint]()
    var bright = Set<CableKey>()
    var zoom: CGFloat = 0
    var ties = 0
    // Something outside the sim changed (the tie stroke): draw once more.
    var dirty = false
}

extension CanvasView {
    // Pixels around a cable or tie that still count as touching it.
    private static let grabReach: CGFloat = 7
    private static let cableLift: CGFloat = 0.3
    // A tie stroke shorter than this on screen is a click, not a stroke.
    private static let minStroke: CGFloat = 10

    func setupCables() {
        worldView.addSubview(cableView, positioned: .below, relativeTo: nil)
        cableView.start { [weak self] in self?.cableTick() }
    }

    private func cableEdges() -> [CableKey: CableSim.Edge] {
        var out = [CableKey: CableSim.Edge]()

        for (id, pane) in panes {
            guard let parent = pane.meta.parent, let p = panes[parent] else { continue }
            out[CableKey(parent: parent, child: id)] = CableSim.Edge(parent: p.meta.rect,
                                                                    child: pane.meta.rect)
        }
        return out
    }

    // A window's own color: its host's (remote), else its group's, else
    // hashed from its name, repo, or directory onto the palette. Both ends
    // of a cable wear their window's color and blend between them; the
    // `cable-color` config (hex or palette:N) paints every cable one color.
    private func windowColor(_ id: PaneID) -> NSColor {
        if let spec = GCTConfig.current.cableColor {
            return GroupColor.resolve(spec, key: id.description)
        }

        let meta = panes[id]?.meta
        if let host = meta?.host, let c = HostStyle.color(for: host) { return c }

        if let g = groupOf(id), let group = groupMetas[g] {
            return GroupColor.resolve(group.color, key: group.name ?? g.uuid.uuidString)
        }
        return GroupColor.resolve(nil, key: meta?.name ?? meta?.repoRoot ?? meta?.cwd ?? id.description)
    }

    private func cableTint(_ key: CableKey) -> CableTint {
        CableTint(parent: lifted(windowColor(key.parent)), child: lifted(windowColor(key.child)))
    }

    // Lighter than the tint it may run over, or it vanishes there.
    private func lifted(_ c: NSColor) -> NSColor {
        c.blended(withFraction: Self.cableLift, of: .white) ?? c
    }

    func cableTick() {
        let on = GCTConfig.current.cables
        cableView.isHidden = !on
        guard on else { return }

        let memo = cableMemo
        let edges = cableEdges()
        var dirty = false

        if edges != memo.edges {
            memo.edges = edges
            cableView.sim.setEdges(edges)
            dirty = true
        }
        if cableView.sim.isAwake {
            cableView.sim.step()
            dirty = true
        }

        let tints = Dictionary(uniqueKeysWithValues: edges.keys.map { ($0, cableTint($0)) })
        let bright = Set(edges.keys.filter { $0.parent == focusedID || $0.child == focusedID })
        let zoom = camera.scale
        let ties = cableView.sim.ties.count

        if tints != memo.tints || bright != memo.bright || zoom != memo.zoom || ties != memo.ties
            || memo.dirty {
            memo.tints = tints
            memo.bright = bright
            memo.zoom = zoom
            memo.ties = ties
            memo.dirty = false
            dirty = true
        }
        guard dirty else { return }

        cableView.render(tints: tints, bright: bright, zoom: zoom)
    }

    // MARK: Mouse

    private func cableReach() -> Double {
        Double(camera.screenToWorldDistance(Self.grabReach))
    }

    // Press on a tie grabs it (double-click removes it); press on a cable
    // starts a stroke, and dragging it across strands ties them together.
    // True when the press was ours; anything else pans.
    func cableMouseDown(_ world: CGPoint, clicks: Int) -> Bool {
        guard GCTConfig.current.cables, !cableView.sim.cables.isEmpty else { return false }

        let p = Vec(Double(world.x), Double(world.y))
        let sim = cableView.sim

        if let tie = sim.tie(near: p, radius: cableReach()) {
            if clicks >= 2 {
                sim.removeTie(tie)
            } else {
                cableView.grabbed = tie
            }
            return true
        }

        guard !sim.hits(near: p, radius: cableReach()).isEmpty else { return false }
        cableView.stroke = (p, p)
        cableMemo.dirty = true
        return true
    }

    func cableMouseDragged(_ world: CGPoint) -> Bool {
        let p = Vec(Double(world.x), Double(world.y))

        if let tie = cableView.grabbed {
            cableView.sim.moveTie(tie, to: p)
            return true
        }

        guard let s = cableView.stroke else { return false }
        cableView.stroke = (s.from, p)
        cableMemo.dirty = true
        return true
    }

    func cableMouseUp() -> Bool {
        if cableView.grabbed != nil {
            cableView.grabbed = nil
            cableMemo.dirty = true
            return true
        }

        guard let s = cableView.stroke else { return false }
        cableView.stroke = nil
        cableMemo.dirty = true

        let long = (s.to - s.from).length > Double(camera.screenToWorldDistance(Self.minStroke))
        if long { cableView.sim.addTie(from: s.from, to: s.to, radius: cableReach()) }
        return true
    }
}
