// Cable ties, kept by the daemon that owns the panes.
//
//   daemon ──tieMeta/tieExit──▶ tieSpecs ──syncTies──▶ CableSim ties
//   daemon ◀──setTie/removeTie── tieMade / tieMoved / tieRemoved (the mouse)
//
// A spec is a tie as the daemon holds it (canvas pane ids). The sim shows
// one tie per spec; a spec whose cables are not on the canvas yet waits and
// is retried every tick. Ties across two daemons stay this canvas's own.

import AppKit
import Common

struct TieSpec {
    var meta: TieMeta
    var owner: String
}

// A sim tie showing a spec, and the spot last applied to it: the sim may
// nudge a tie off its spec (a neighbor in the way), which is not news.
struct TieLink {
    var spec: String
    var s: Double
}

extension CanvasView {
    // MARK: From the daemon

    func tiesSnapshot(_ ties: [TieMeta], owner: String) {
        dropTies(owner: owner)
        for t in ties { tieUpsert(t, owner: owner) }
    }

    func tieUpsert(_ tie: TieMeta, owner: String) {
        cableMemo.tieSpecs[tie.id] = TieSpec(meta: hub.inboundTie(tie, owner: owner), owner: owner)
    }

    func tieGone(_ id: String) {
        cableMemo.tieSpecs.removeValue(forKey: id)
    }

    func dropTies(owner: String) {
        cableMemo.tieSpecs = cableMemo.tieSpecs.filter { $0.value.owner != owner }
    }

    // Make the sim's ties match the specs. Runs every cable tick, so it
    // must cost nothing when nothing changed.
    func syncTies() {
        let memo = cableMemo
        let sim = cableView.sim
        let live = Dictionary(uniqueKeysWithValues: sim.ties.map { ($0.id, $0) })

        for (id, link) in memo.tieLinks {
            guard live[id] != nil else {
                memo.tieLinks.removeValue(forKey: id)
                continue
            }
            guard let spec = memo.tieSpecs[link.spec] else {
                sim.removeTie(id)
                memo.tieLinks.removeValue(forKey: id)
                continue
            }
            guard spec.meta.s != link.s, cableView.grabbed != id else { continue }

            sim.slideTie(id, to: spec.meta.s)
            memo.tieLinks[id]?.s = spec.meta.s
        }

        let shown = Set(memo.tieLinks.values.map(\.spec))
        for (id, spec) in memo.tieSpecs where !shown.contains(id) {
            let members = spec.meta.strands.map {
                CableTie.Member(key: CableKey(parent: $0.parent, child: $0.child), delta: $0.delta)
            }
            guard let tie = sim.restoreTie(members, s: spec.meta.s) else { continue }
            memo.tieLinks[tie] = TieLink(spec: id, s: spec.meta.s)
        }
    }

    // MARK: From the mouse

    private func strands(_ tie: CableTie) -> [TieMeta.Strand] {
        tie.members.map { TieMeta.Strand(parent: $0.key.parent, child: $0.key.child, delta: $0.delta) }
    }

    func tieMade(_ id: Int) {
        guard let tie = cableView.sim.ties.first(where: { $0.id == id }) else { return }

        let meta = TieMeta(s: tie.s, strands: strands(tie))
        guard let owner = hub.setTie(meta) else { return }

        cableMemo.tieSpecs[meta.id] = TieSpec(meta: meta, owner: owner)
        cableMemo.tieLinks[id] = TieLink(spec: meta.id, s: meta.s)
    }

    func tieMoved(_ id: Int) {
        let memo = cableMemo
        guard let tie = cableView.sim.ties.first(where: { $0.id == id }),
              let link = memo.tieLinks[id], var spec = memo.tieSpecs[link.spec] else { return }

        // Strands too: an older spec's deltas are already folded into `s`.
        spec.meta.s = tie.s
        spec.meta.strands = strands(tie)
        memo.tieSpecs[link.spec] = spec
        memo.tieLinks[id]?.s = tie.s
        _ = hub.setTie(spec.meta)
    }

    func tieRemoved(_ id: Int) {
        let memo = cableMemo
        guard let link = memo.tieLinks.removeValue(forKey: id),
              let spec = memo.tieSpecs.removeValue(forKey: link.spec) else { return }

        hub.removeTie(link.spec, owner: spec.owner)
    }
}
