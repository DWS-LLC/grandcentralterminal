// StarCraft-style control groups: a numbered slot remembers some panes of one
// session. Pure logic: tested without a canvas.
//
//   assign(1, "local", {a b})   1 ─► local {a b}
//   assign(2, "enterprise", {x})  2 ─► enterprise {x}
//   forget(x)                   2 gone (nothing left in it)
//
// A session detaching kills its panes one by one, so forget() empties its slots.

import Foundation

public struct CommandGroups {
    public struct Slot: Equatable {
        public let owner: String
        public let ids: Set<PaneID>
    }

    private var slots: [Int: Slot] = [:]

    public init() {}

    // Replaces whatever the slot held. Nothing to remember: slot untouched.
    public mutating func assign(_ slot: Int, owner: String, ids: Set<PaneID>) {
        guard !ids.isEmpty else {
            return
        }

        slots[slot] = Slot(owner: owner, ids: ids)
    }

    public func recall(_ slot: Int) -> Slot? {
        return slots[slot]
    }

    // Slots remembering this pane, ascending: what its titlebar badges.
    public func slots(holding id: PaneID) -> [Int] {
        return slots.filter { $0.value.ids.contains(id) }.keys.sorted()
    }

    // A pane died: out of every slot, and a slot with nobody left goes too.
    public mutating func forget(_ id: PaneID) {
        for (slot, held) in slots where held.ids.contains(id) {
            let rest = held.ids.subtracting([id])
            slots[slot] = rest.isEmpty ? nil : Slot(owner: held.owner, ids: rest)
        }
    }
}
