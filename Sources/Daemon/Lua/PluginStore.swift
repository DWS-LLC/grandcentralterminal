// Where plugins live, and what is known about them.
//
//   ~/.config/gct/
//   ├── config.toml        [plugin.<name>] holds a plugin's options
//   ├── plugins.lock       what `gctd plugin install` pinned, commit by commit
//   └── plugins/
//       └── leaf/          a git clone, or any folder you drop in
//           ├── init.lua   returns { setup = function(opts) ... end }
//           ├── lua/       require("x") finds lua/x.lua
//           └── plugin.toml  optional: version, description
//
// Autoload runs each folder as its own `gctd lua --plugin <name>` process.
// This file only knows the layout: no git, no processes.

import Foundation
import Common

struct PluginError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

struct PluginManifest {
    var version = ""
    var description = ""
}

// One line of plugins.lock: where it came from and the commit it sits at.
struct PluginPin: Codable, Equatable {
    var source: String
    var ref: String?
    var commit: String
}

struct PluginLock: Codable {
    var plugins = [String: PluginPin]()
}

struct Plugin {
    let name: String
    let path: String
    let manifest: PluginManifest
    // nil: put there by hand, not by gctd.
    let pin: PluginPin?
}

enum PluginStore {
    static let initFile = "init.lua"

    private static let folder = "/plugins"
    private static let lockFile = "/plugins.lock"
    private static let manifestFile = "plugin.toml"
    private static let optionsPrefix = "plugin."
    private static let gitDir = ".git"
    private static let enabledKey = "enabled"
    private static let nameChars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    static func dir() -> String {
        PeerConfig.dir() + folder
    }

    static func path(of name: String) -> String {
        dir() + "/" + name
    }

    static func hasEntry(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: path(of: name))
    }

    static func hasInit(at dir: String) -> Bool {
        FileManager.default.fileExists(atPath: dir + "/" + initFile)
    }

    // A name becomes a folder under plugins/ and a section in config.toml, so
    // nothing that could climb out ("..", "a/b") or hide (".x") gets through.
    static func valid(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }

        return name.unicodeScalars.allSatisfy { nameChars.contains($0) }
    }

    // MARK: Listing

    // Every folder in plugins/ with an init.lua, by name. Dot folders are
    // skipped: that is where an install in progress sits.
    static func installed() -> [Plugin] {
        let fm = FileManager.default
        let pins = (try? readLock())?.plugins ?? [:]
        let names = ((try? fm.contentsOfDirectory(atPath: dir())) ?? []).sorted()
        var out = [Plugin]()

        for name in names where valid(name) {
            let path = path(of: name)
            guard hasInit(at: path) else { continue }

            out.append(Plugin(name: name, path: path, manifest: manifest(at: path), pin: pins[name]))
        }

        return out
    }

    static func find(_ name: String) -> Plugin? {
        installed().first { $0.name == name }
    }

    private static func manifest(at path: String) -> PluginManifest {
        guard let text = try? String(contentsOfFile: path + "/" + manifestFile, encoding: .utf8),
              let root = TOML.parse(text)[""] else { return PluginManifest() }

        return PluginManifest(version: root["version"] ?? "", description: root["description"] ?? "")
    }

    // MARK: Options

    // The raw [plugin.<name>] table of config.toml; the caller types the values.
    static func options(of name: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: PeerConfig.path(), encoding: .utf8) else { return [:] }

        return TOML.parse(text)[optionsPrefix + name] ?? [:]
    }

    // `enabled = false` in the plugin's table keeps it from starting.
    static func isEnabled(_ options: [String: String]) -> Bool {
        options[enabledKey] != "false"
    }

    // MARK: Change detection

    // The newest mtime in the folder, .git aside: a pull or an edit moves it,
    // and autoload restarts the plugin. A symlinked folder is followed.
    static func stamp(of plugin: Plugin) -> Date {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: plugin.path).resolvingSymlinksInPath().path
        var newest = Date.distantPast
        guard let walk = fm.enumerator(atPath: root) else { return newest }

        for case let rel as String in walk {
            if rel == gitDir {
                walk.skipDescendants()
                continue
            }

            guard let at = (try? fm.attributesOfItem(atPath: root + "/" + rel))?[.modificationDate] as? Date else { continue }

            newest = max(newest, at)
        }

        return newest
    }

    // MARK: Running

    // What `gctd lua --plugin` runs: put lua/ on the module path, load init.lua,
    // hand its setup() the options (gct.args).
    static func boot(_ plugin: Plugin) -> String {
        """
        local root = \(luaQuoted(plugin.path))
        package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
        local plugin = dofile(root .. "/\(initFile)")
        if type(plugin) == "table" and type(plugin.setup) == "function" then
          plugin.setup(gct.args)
        end
        """
    }

    private static func luaQuoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        return "\"" + escaped + "\""
    }

    // MARK: Lock

    // A missing lock is empty; one that won't parse is an error, not a reset:
    // starting over would forget every pin.
    static func readLock() throws -> PluginLock {
        guard let data = FileManager.default.contents(atPath: PeerConfig.dir() + lockFile) else { return PluginLock() }

        do {
            return try JSONDecoder().decode(PluginLock.self, from: data)
        } catch {
            throw PluginError("\(lockFile.dropFirst()) is not valid JSON (\(error.localizedDescription)); fix or remove it")
        }
    }

    static func writeLock(_ lock: PluginLock) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            try FileManager.default.createDirectory(atPath: PeerConfig.dir(), withIntermediateDirectories: true)
            try encoder.encode(lock).write(to: URL(fileURLWithPath: PeerConfig.dir() + lockFile), options: .atomic)
        } catch {
            throw PluginError("can't write \(lockFile.dropFirst()): \(error.localizedDescription)")
        }
    }
}
