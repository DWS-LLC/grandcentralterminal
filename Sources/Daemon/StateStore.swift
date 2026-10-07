// Debounced pane-metadata persistence.

import Foundation
import Common

final class StateStore {
    private let path: String
    private let lock = NSLock()
    private var pending: [PaneMeta]?
    private var dirty = false

    init(path: String) {
        self.path = path
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
    }

    func load() -> [PaneMeta] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([PaneMeta].self, from: data)) ?? []
    }

    func scheduleSave(_ metas: [PaneMeta]) {
        lock.lock()
        pending = metas
        dirty = true
        lock.unlock()

        // Coalesce rapid mutations; save 1s after the last call.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard dirty, let metas = pending else { return }
        dirty = false
        pending = nil
        if let data = try? JSONEncoder().encode(metas) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
