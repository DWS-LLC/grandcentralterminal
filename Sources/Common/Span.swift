// Durations as people type them: "90s", "10m", "2h", "7d". A bare number
// is seconds. Shared by `gctd wait for=` and config.toml's keep-open-ttl.
//
// Pure string math, same as Placement: no AppKit, runs in the CLI.

import Foundation

public enum Span {
    private static let units: [Character: TimeInterval] = [
        "s": 1, "m": 60, "h": 3600, "d": 86400,
    ]

    // Seconds, or nil when `raw` isn't a non-negative finite duration.
    public static func parse(_ raw: String) -> TimeInterval? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let last = text.last else { return nil }

        let scale = units[last]
        let number = scale == nil ? text : String(text.dropLast())
        guard let n = Double(number), n.isFinite, n >= 0 else { return nil }

        return n * (scale ?? 1)
    }
}
