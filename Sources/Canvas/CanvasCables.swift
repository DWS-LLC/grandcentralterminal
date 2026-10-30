// Cables between a pane and the panes it spawned.
//
//   pane.meta.parent ──► edges (world rects) ──► CableSim ──► CableView
//                                                  ▲
//   drag across cables: tie them together          │ ties slide along the
//   drag a tie: slide it     double-click: remove ─┘ cable, never overlap
//
// A 60 Hz tick keeps the sim fed and renders only while something moves.
// Ties you make or slide are sent to the daemon that owns the panes, which
// keeps them (and `gctd tie` makes them too); CanvasTies.swift keeps the sim
// matching what the daemon holds.

import AppKit
import Common

// What the last render saw, so a still canvas costs a few comparisons.
final class CableMemo {
    var edges = [CableKey: CableSim.Edge]()
    // Picked when the cable first appears, from its two windows' names,
    // and kept: renaming a window later does not recolor its cables.
    var colors = [CableKey: NSColor]()
    var bright = Set<CableKey>()
    var zoom: CGFloat = 0
    var ties = 0
    // Something outside the sim changed (the tie stroke): draw once more.
    var dirty = false
    var renderedColors = [CableKey: NSColor]()
    // Ties the daemons hold (canvas pane ids), and which sim tie shows each.
    var tieSpecs = [String: TieSpec]()
    var tieLinks = [Int: TieLink]()
}

extension CanvasView {
    // Pixels around a cable or tie that still count as touching it.
    private static let grabReach: CGFloat = 14
    private static let cableLift: CGFloat = 0.3
    // ANSI slots with a hue (not the blacks and whites), normal then bright.
    private static let cablePalette = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14]
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

    // One palette color per cable, hashed from "start -> end" window names
    // the moment the cable gets its color. `cable-color` (hex or palette:N)
    // paints every cable the same instead. Nil until both windows have a
    // name (auto names land a beat after a pane appears).
    private func pickColor(_ key: CableKey) -> NSColor? {
        if let spec = GCTConfig.current.cableColor {
            return lifted(GroupColor.resolve(spec, key: key.child.description))
        }

        guard let from = panes[key.parent].flatMap({ $0.meta.name ?? $0.autoName }),
              let to = panes[key.child].flatMap({ $0.meta.name ?? $0.autoName }) else { return nil }
        let slot = Self.cablePalette[Int(("\(from) -> \(to)").gctHash) % Self.cablePalette.count]
        return lifted(GroupColor.resolve("\(GroupStyle.palettePrefix)\(slot)", key: ""))
    }

    private func cableColors(_ keys: Set<CableKey>) -> [CableKey: NSColor] {
        let memo = cableMemo
        memo.colors = memo.colors.filter { keys.contains($0.key) }

        for key in keys where memo.colors[key] == nil || GCTConfig.current.cableColor != nil {
            guard let c = pickColor(key) else { continue }
            memo.colors[key] = c
        }
        return memo.colors
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

        // Before the edges: a new cable checks which panes it starts across.
        cableView.sim.setPanes(panes.mapValues { $0.meta.rect })
        cableView.sim.setSlack(GCTConfig.current.cableSlack)
        if edges != memo.edges {
            memo.edges = edges
            cableView.sim.setEdges(edges)
            dirty = true
        }
        syncTies()
        if cableView.sim.isAwake {
            cableView.sim.step()
            dirty = true
        }

        let colors = cableColors(Set(edges.keys))
        let bright = Set(edges.keys.filter { $0.parent == focusedID || $0.child == focusedID })
        let zoom = camera.scale
        let ties = cableView.sim.ties.count

        if colors != memo.renderedColors || bright != memo.bright || zoom != memo.zoom || ties != memo.ties
            || memo.dirty {
            memo.renderedColors = colors
            memo.bright = bright
            memo.zoom = zoom
            memo.ties = ties
            memo.dirty = false
            dirty = true
        }
        guard dirty else { return }

        cableView.render(colors: colors, bright: bright, zoom: zoom)
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
                tieRemoved(tie)
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
        if let tie = cableView.grabbed {
            tieMoved(tie)
            cableView.grabbed = nil
            cableMemo.dirty = true
            return true
        }

        guard let s = cableView.stroke else { return false }
        cableView.stroke = nil
        cableMemo.dirty = true

        let long = (s.to - s.from).length > Double(camera.screenToWorldDistance(Self.minStroke))
        if long, let tie = cableView.sim.addTie(from: s.from, to: s.to, radius: cableReach()) {
            tieMade(tie)
        }
        return true
    }
}
