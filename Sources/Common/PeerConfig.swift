// [host.<name>] tables of config.toml: the machines this one can reach.
// The canvas reads them for its session list and colors, gctd for its peer
// links, so both parse them here.

import Foundation

public struct PeerHost: Equatable, Sendable {
    public var name: String   // [host.<name>] label
    public var host: String   // TCP address (ssh-tunnel endpoint ok)
    public var port: UInt16
    public var token: String
    public var proxy: String  // ssh jump host; "" = direct

    public init(name: String, host: String, port: UInt16 = GCTDefaultPort,
                token: String = "", proxy: String = "") {
        self.name = name; self.host = host; self.port = port
        self.token = token; self.proxy = proxy
    }
}

public enum PeerConfig {
    private static let hostPrefix = "host."

    /// GCT_CONFIG_DIR swaps the whole dir (test/demo instances); else
    /// $HOME/.config/gct on both platforms.
    public static func dir() -> String {
        let env = ProcessInfo.processInfo.environment
        if let d = env["GCT_CONFIG_DIR"], !d.isEmpty {
            return d
        }

        let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return home + "/.config/gct"
    }

    public static func path() -> String {
        dir() + "/config.toml"
    }

    /// Every table with a non-empty `host` key, sorted by name.
    public static func hosts(in tables: [String: [String: String]]) -> [PeerHost] {
        var out = [PeerHost]()
        for (section, vals) in tables where section.hasPrefix(hostPrefix) {
            let name = String(section.dropFirst(hostPrefix.count))
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let h = vals["host"]?.trimmingCharacters(in: .whitespaces),
                  !h.isEmpty else { continue }

            let port = vals["port"].flatMap(UInt16.init).flatMap { $0 > 0 ? $0 : nil }
            out.append(PeerHost(name: name, host: h, port: port ?? GCTDefaultPort,
                                token: vals["token"] ?? "",
                                proxy: vals["proxy"]?.trimmingCharacters(in: .whitespaces) ?? ""))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// How long an ended keep-open pane lingers before gctd closes it.
    /// `keep-open-ttl` in config.toml ("7d", "12h", "0" = until closed).
    public static let defaultKeepOpenTTL: TimeInterval = 7 * 24 * 3600

    public static func keepOpenTTL() -> TimeInterval {
        guard let text = try? String(contentsOfFile: path(), encoding: .utf8),
              let raw = TOML.parse(text)[""]?["keep-open-ttl"],
              let ttl = Span.parse(raw) else {
            return defaultKeepOpenTTL
        }
        return ttl
    }

    /// Empty when the file is missing or unreadable.
    public static func load() -> [PeerHost] {
        guard let text = try? String(contentsOfFile: path(), encoding: .utf8) else {
            return []
        }
        return hosts(in: TOML.parse(text))
    }
}
