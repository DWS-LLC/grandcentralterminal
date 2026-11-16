// What was used last, like alt-tab's list: the pane switcher and the command
// palette order themselves by it. Pure logic: tested without a canvas.
//
//   touch(c) on [a b c d] ─► [c a b d]      newest first
//   sorted([x a z b])     ─► [a b x z]      seen ones by recency, unseen ones after, in order

import Foundation

public struct Recency<Key: Hashable> {
    // Newest first.
    public private(set) var keys: [Key]
    private let limit: Int

    public init(keys: [Key] = [], limit: Int = 200) {
        self.limit = limit
        self.keys = Array(keys.prefix(limit))
    }

    public mutating func touch(_ key: Key) {
        keys.removeAll { $0 == key }
        keys.insert(key, at: 0)
        if keys.count > limit {
            keys.removeLast(keys.count - limit)
        }
    }

    public mutating func forget(_ key: Key) {
        keys.removeAll { $0 == key }
    }

    // Seen ones first, newest first; the rest keep their order.
    public func sorted<T>(_ items: [T], by key: (T) -> Key) -> [T] {
        let rank = Dictionary(keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let unseen = keys.count

        return items.enumerated().sorted {
            let a = rank[key($0.element)] ?? unseen
            let b = rank[key($1.element)] ?? unseen
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
    }
}

extension Recency: Sendable where Key: Sendable {}
