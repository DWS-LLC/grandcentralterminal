// Debounced pane-metadata persistence.

import Foundation
import Common

final class StateStore {
    private let path: String
    private let lock = NSLock()
    private var pending: SavedState?
    private var dirty = false

    init(path: String) {
        self.path = path
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
    }

    func load() -> SavedState {
        guard let data = FileManager.default.contents(atPath: path) else {
            return SavedState()
        }
        // New object form; falls back to the legacy bare pane array.
        if let s = try? JSONDecoder().decode(SavedState.self, from: data) {
            return s
        }
        if let panes = try? JSONDecoder().decode([PaneMeta].self, from: data) {
            return SavedState(panes: panes, groups: [])
        }
        return SavedState()
    }

    func scheduleSave(_ state: SavedState) {
        lock.lock()
        pending = state
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
        guard dirty, let state = pending else { return }
        dirty = false
        pending = nil
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

// Persisted layout: panes plus groups. Legacy files decode as a bare
// [PaneMeta] (see load()); writing is always the object form.
struct SavedState: Codable, Sendable {
    var panes: [PaneMeta]
    var groups: [GroupMeta]
    init(panes: [PaneMeta] = [], groups: [GroupMeta] = []) {
        self.panes = panes; self.groups = groups
    }
    enum CodingKeys: String, CodingKey { case panes, groups }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        panes = try c.decodeIfPresent([PaneMeta].self, forKey: .panes) ?? []
        groups = try c.decodeIfPresent([GroupMeta].self, forKey: .groups) ?? []
    }
}
