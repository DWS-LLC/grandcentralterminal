// A daemon's stable identity. Peers name their guest panes after it, so the
// host can tell whose guests are whose across reconnects and restarts.

import Foundation

enum DaemonID {
    /// Reads the id at `path`, minting and saving one on first start.
    static func load(path: String) -> String {
        if let data = FileManager.default.contents(atPath: path),
           let text = String(data: data, encoding: .utf8) {
            let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty {
                return id
            }
        }

        let fresh = UUID().uuidString
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? Data(fresh.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        return fresh
    }
}
