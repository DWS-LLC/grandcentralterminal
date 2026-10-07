// Bounded byte ring for pane scrollback replay on attach.
// Keeps the newest `cap` bytes; replay emits in stream order.

import Foundation

final class Ring {
    private let cap: Int
    private var buf = Data()
    private(set) var dropped: UInt64 = 0  // bytes evicted from the front

    init(cap: Int) {
        self.cap = max(1, cap)
    }

    func append(_ data: Data) {
        buf.append(data)
        if buf.count > cap {
            let drop = buf.count - cap
            dropped += UInt64(drop)
            buf.removeFirst(drop)
        }
    }

    // Snapshot of retained bytes in stream order.
    func snapshot() -> Data { buf }

    var count: Int { buf.count }
}
