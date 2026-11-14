// Hook entries in an agent's JSON settings (Claude's settings.json, Codex's
// hooks.json): put ours in, take ours out, leave everything else alone.
//
//   { "hooks": { "SessionStart": [ { "matcher": "",
//                                    "hooks": [ { "type": "command",
//                                                 "command": "gctd agent context || exit 0",
//                                                 "timeout": 15 } ] } ] } }
//
// An entry is ours when it runs gctd's `agent context` or `notify self --hook`,
// whatever path (or older verb) wrote it, so reruns migrate it in place
// instead of stacking a twin.

import Foundation

typealias JSONObject = [String: Any]

struct HookSpec {
    let event: String
    let command: String
    let timeout: Int
    let matcher: String?
}

enum JSONFile {
    case missing
    case unreadable
    case parsed(JSONObject)
}

private let ownedVerbs = ["agent context", "agent-setup context", "notify self --hook"]

private func isOurs(_ hook: JSONObject) -> Bool {
    guard let cmd = hook["command"] as? String else { return false }

    return cmd.contains("gctd") && ownedVerbs.contains { cmd.contains($0) }
}

// MARK: - File

func loadJSON(_ path: String) -> JSONFile {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return .missing }
    guard let data = fm.contents(atPath: path) else { return .unreadable }
    guard !data.isEmpty else { return .parsed([:]) }
    guard let obj = try? JSONSerialization.jsonObject(with: data),
          let root = obj as? JSONObject else { return .unreadable }

    return .parsed(root)
}

// Atomic, so a crash never leaves half a settings file.
func saveJSON(_ root: JSONObject, to path: String) throws {
    let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try JSONSerialization.data(withJSONObject: root, options: opts)
    data.append(Data("\n".utf8))

    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

// Compares canonical bytes, not NSDictionary.isEqual: swift-corelibs bridges
// parsed values (numbers, empty strings) differently from ours and reports
// equal files as different, so setup would rewrite them on every run.
func sameJSON(_ a: JSONObject, _ b: JSONObject) -> Bool {
    let opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    guard let x = try? JSONSerialization.data(withJSONObject: a, options: opts),
          let y = try? JSONSerialization.data(withJSONObject: b, options: opts) else { return false }

    return x == y
}

// MARK: - Merge

func hasOurHooks(_ root: JSONObject) -> Bool {
    let events = (root["hooks"] as? JSONObject) ?? [:]
    for groups in events.values {
        for group in (groups as? [JSONObject]) ?? [] {
            let hs = (group["hooks"] as? [JSONObject]) ?? []
            if hs.contains(where: isOurs) {
                return true
            }
        }
    }

    return false
}

// `root` with every spec in place. Idempotent: merging twice changes nothing.
func addingHooks(_ root: JSONObject, _ specs: [HookSpec]) -> JSONObject {
    var root = root
    var events = (root["hooks"] as? JSONObject) ?? [:]
    for spec in specs {
        let groups = (events[spec.event] as? [JSONObject]) ?? []
        events[spec.event] = placing(spec, in: groups)
    }
    root["hooks"] = events

    return root
}

// The first entry of ours becomes `spec`, later twins go, and with none a
// fresh group is appended. A group we emptied is dropped; one that was
// empty to begin with is not ours to touch.
private func placing(_ spec: HookSpec, in groups: [JSONObject]) -> [JSONObject] {
    var found = false
    var out = [JSONObject]()

    for var group in groups {
        guard let hs = group["hooks"] as? [JSONObject] else {
            out.append(group)
            continue
        }

        var kept = [JSONObject]()
        for hook in hs {
            guard isOurs(hook) else {
                kept.append(hook)
                continue
            }
            if found {
                continue
            }

            found = true
            var mine = hook
            mine["command"] = spec.command
            mine["timeout"] = spec.timeout
            kept.append(mine)
        }

        if kept.isEmpty && !hs.isEmpty {
            continue
        }
        group["hooks"] = kept
        out.append(group)
    }

    if !found {
        out.append(freshGroup(spec))
    }

    return out
}

private func freshGroup(_ spec: HookSpec) -> JSONObject {
    let hook: JSONObject = ["type": "command", "command": spec.command, "timeout": spec.timeout]
    var group: JSONObject = ["hooks": [hook]]
    if let matcher = spec.matcher {
        group["matcher"] = matcher
    }

    return group
}

// MARK: - Strip

// `root` without any entry of ours; events and the `hooks` key we emptied go
// too, so a removal leaves the file as it was before setup.
func removingHooks(_ root: JSONObject) -> JSONObject {
    var root = root
    guard var events = root["hooks"] as? JSONObject else { return root }

    var changed = false
    for (event, value) in events {
        guard let groups = value as? [JSONObject] else { continue }

        var touched = false
        let left = groups.compactMap { group -> JSONObject? in
            guard var hs = group["hooks"] as? [JSONObject] else { return group }

            let before = hs.count
            hs.removeAll(where: isOurs)
            guard hs.count != before else { return group }

            touched = true
            guard !hs.isEmpty else { return nil }

            var kept = group
            kept["hooks"] = hs
            return kept
        }

        guard touched else { continue }

        changed = true
        events[event] = left.isEmpty ? nil : left
    }
    guard changed else { return root }
    root["hooks"] = events.isEmpty ? nil : events

    return root
}
