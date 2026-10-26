// Cables between a pane and the panes it spawned.
//
//   pane.meta.parent ──► edges (world rects) ──► CableSim ──► CableView
//                                                  ▲
//   double-click a cable: add a tie                │ ties slide along the
//   drag a tie: slide it     double-click: remove ─┘ cable, never overlap
//
// A 60 Hz tick keeps the sim fed and renders only while something moves.
// Ties live for the session (pane ids are per-session on the canvas).

import AppKit
import Common

// What the last render saw, so a still canvas costs a few comparisons.
final class CableMemo {
    var edges = [CableKey: CableSim.Edge]()
    var colors = [CableKey: NSColor]()
    var bright = Set<CableKey>()
    var zoom: CGFloat = 0
    var ties = 0
}

extension CanvasView {
    // Pixels around a cable or tie that still count as touching it.
    private static let grabReach: CGFloat = 7
    private static let cableLift: CGFloat = 0.45

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

    // One color per parent: its group's color, else hashed from its repo or
    // directory, so a fan-out reads as one family.
    private func cableColor(_ key: CableKey) -> NSColor {
        let base: NSColor
        if let g = groupOf(key.parent), let meta = groupMetas[g] {
            base = GroupColor.resolve(meta.color, key: meta.name ?? g.uuid.uuidString)
        } else {
            let meta = panes[key.parent]?.meta
            base = GroupColor.resolve(nil, key: meta?.repoRoot ?? meta?.cwd ?? key.parent.description)
        }
        // Lighter than the group tint it runs over, or it vanishes there.
        return base.blended(withFraction: Self.cableLift, of: .white) ?? base
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

        let colors = Dictionary(uniqueKeysWithValues: edges.keys.map { ($0, cableColor($0)) })
        let bright = Set(edges.keys.filter { $0.parent == focusedID || $0.child == focusedID })
        let zoom = camera.scale
        let ties = cableView.sim.ties.count

        if colors != memo.colors || bright != memo.bright || zoom != memo.zoom || ties != memo.ties {
            memo.colors = colors
            memo.bright = bright
            memo.zoom = zoom
            memo.ties = ties
            dirty = true
        }
        guard dirty else { return }

        cableView.render(colors: colors, bright: bright, zoom: zoom)
    }

    // MARK: Mouse

    private func cableReach() -> Double {
        Double(camera.screenToWorldDistance(Self.grabReach))
    }

    // Press on a tie grabs it; a double-click on a tie removes it, on a bare
    // cable adds one. True when the press was ours.
    func cableMouseDown(_ world: CGPoint, clicks: Int) -> Bool {
        guard GCTConfig.current.cables, !cableView.sim.cables.isEmpty else { return false }

        let p = Vec(Double(world.x), Double(world.y))
        let sim = cableView.sim

        if let tie = sim.tie(near: p, radius: cableReach()) {
            if clicks >= 2 {
                sim.removeTie(tie)
                return true
            }
            cableView.grabbed = tie
            return true
        }

        guard clicks >= 2, sim.addTie(at: p, radius: cableReach()) != nil else { return false }
        return true
    }

    func cableMouseDragged(_ world: CGPoint) -> Bool {
        guard let tie = cableView.grabbed else { return false }
        cableView.sim.moveTie(tie, to: Vec(Double(world.x), Double(world.y)))
        return true
    }

    func cableMouseUp() -> Bool {
        guard cableView.grabbed != nil else { return false }
        cableView.grabbed = nil
        cableMemo.ties = -1
        return true
    }
}
