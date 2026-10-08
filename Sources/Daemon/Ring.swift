// Bounded byte ring for pane scrollback replay on attach.
// Keeps the newest `cap` bytes; replay emits in stream order.
//
// Chunked: appends are O(1) (no memmove of retained bytes) and eviction
// drops whole head chunks. Snapshot concatenates (attach-time only, rare).
// Self-locked: appends run on the pane reader thread, snapshots on the
// server thread.

import Foundation

final class Ring {
    private let cap: Int
    private var chunks = [Data]()
    private var total = 0
    private(set) var dropped: UInt64 = 0  // bytes evicted from the front
    private let lock = NSLock()

    init(cap: Int) {
        self.cap = max(1, cap)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        chunks.append(data)
        total += data.count
        guard total > cap else { return }
        var drop = total - cap
        dropped += UInt64(drop)
        while drop > 0, !chunks.isEmpty {
            let n = chunks[0].count
            if n <= drop {
                drop -= n
                total -= n
                chunks.removeFirst()
            } else {
                // Partial head trim: one bounded copy of the survivor.
                chunks[0] = chunks[0].subdata(in: drop..<n)
                total -= drop
                drop = 0
            }
        }
    }

    // Snapshot of retained bytes in stream order.
    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        var out = Data(capacity: total)
        for c in chunks { out.append(c) }
        return out
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}
