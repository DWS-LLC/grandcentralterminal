// Debounced pane-metadata persistence.

import Foundation
import Common

final class StateStore {
    private let path: String
    private let lock = NSLock()
    private var pending: SavedState?
    // A flush is queued; later calls only replace pending.
    private var armed = false
    private static let saveDelay: TimeInterval = 1

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

    // Callers hold the server lock, so pending always ends up newest.
    // Coalesce: at most one write per saveDelay, carrying the latest state.
    func scheduleSave(_ state: SavedState) {
        lock.lock(); defer { lock.unlock() }
        pending = state
        guard !armed else {
            return
        }

        armed = true
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.saveDelay) { [weak self] in
            self?.flush()
        }
    }

    // Exit paths: the debounce would otherwise drop the last second.
    func saveNow() {
        flush()
    }

    private func flush() {
        lock.lock()
        defer { lock.unlock() }
        armed = false
        guard let state = pending else { return }
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
    var ties: [TieMeta]
    init(panes: [PaneMeta] = [], groups: [GroupMeta] = [], ties: [TieMeta] = []) {
        self.panes = panes; self.groups = groups; self.ties = ties
    }
    enum CodingKeys: String, CodingKey { case panes, groups, ties }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        panes = try c.decodeIfPresent([PaneMeta].self, forKey: .panes) ?? []
        groups = try c.decodeIfPresent([GroupMeta].self, forKey: .groups) ?? []
        ties = try c.decodeIfPresent([TieMeta].self, forKey: .ties) ?? []
    }
}
