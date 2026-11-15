// gct.bind / gct.mode: one script's key bindings. The script keeps the list;
// the canvas keeps the keyboard. Every change sends the whole list over, and
// a bound key hit on the canvas comes back as an event naming the script.
//
//   gct.bind ─► ScriptKeys ─► KeymapWire ─► daemon ─► canvas KeyEngine
//                  ▲                                       │ key hit
//                  └────── state.key event ◄── daemon ◄────┘
//
// The daemon takes the bindings down when the script's connection closes, so
// a script that dies leaves nothing behind.

import Foundation
import Common

private let modeEnter = "client.mode.enter"
private let firstSerial = 1

// What a bound key runs, when the canvas hands it back.
enum KeyRun {
    case function(LuaFunc)
    case action(String, args: [String: Any]?)
}

struct KeyFiring {
    var run: KeyRun
    var fields: [String: Any]
    var label: String
    // Set when the canvas is holding the key until the function answers.
    var req: String?
}

final class ScriptKeys {
    private struct Entry {
        var serial: Int
        var keys: String
        var address: KeyAddress
        var run: KeyRun?
        var fnID: Int?
        var source: String

        // Unbound on purpose: it stops a default (or a binding outside a mode).
        var isBlock: Bool { run == nil }
    }

    private struct Mode {
        var exclusive: Bool
        var source: String
    }

    let token = UUID().uuidString
    private var entries = [Entry]()
    private var modes = [String: Mode]()
    private var serial = firstSerial
    private var nextFn = 1
    private let publish: (KeymapWire) -> Void
    private let same: (LuaFunc, LuaFunc) -> Bool

    init(publish: @escaping (KeymapWire) -> Void, same: @escaping (LuaFunc, LuaFunc) -> Bool) {
        self.publish = publish
        self.same = same
    }

    // Enough to keep the script alive: a keys-only script has no handlers.
    var hasBindings: Bool { entries.contains { !$0.isBlock } }

    // MARK: Bind

    func bind(_ keys: String, _ run: KeyRun, source: String) throws {
        let address = try parse(keys)
        try check(run, in: address)

        var fnID: Int?
        if case .function = run {
            fnID = nextFn
            nextFn += 1
        }

        add(Entry(serial: serial, keys: keys, address: address, run: run, fnID: fnID, source: source))
    }

    private func add(_ e: Entry) {
        entries.append(e)
        serial += 1
        send()
    }

    private func parse(_ keys: String) throws -> KeyAddress {
        guard let address = KeyAddress(keys) else { throw ScriptError("bad key \"\(keys)\": like cmd+d, ctrl+b>c or resize/left") }

        return address
    }

    private func check(_ run: KeyRun, in address: KeyAddress) throws {
        // Rex's rule: a mode is a table of named actions. Lua goes in an action.
        if case .function = run, address.mode != nil {
            throw ScriptError("a mode binds actions, not functions: define one with gct.action and bind its name")
        }

        guard case .action(let name, let args) = run else { return }
        guard !name.isEmpty else { throw ScriptError("an action name is required") }
        guard name == modeEnter else { return }

        guard let target = args?["name"] as? String, KeyAddress.validMode(target) else {
            throw ScriptError("\(modeEnter) needs name = a mode (lowercase letters, digits, _ and -)")
        }
    }

    // MARK: Mode

    func mode(_ name: String, exclusive: Bool, source: String) throws {
        guard KeyAddress.validMode(name) else { throw ScriptError("mode names are lowercase letters, digits, _ and -") }

        modes[name] = Mode(exclusive: exclusive, source: source)
        send()
    }

    // MARK: Unbind

    // The bindings of this script at that key, or only those with that target.
    // With no target the key is also blocked: defaults and outside-the-mode
    // bindings stop firing there. Returns how many of ours went.
    func unbind(_ keys: String, only target: KeyRun?, source: String) throws -> Int {
        let address = try parse(keys)
        let before = entries.count

        entries.removeAll { $0.address == address && !$0.isBlock && matches($0.run, target) }
        let removed = before - entries.count

        if target == nil {
            entries.removeAll { $0.address == address && $0.isBlock }
            entries.append(Entry(serial: serial, keys: keys, address: address, run: nil, fnID: nil, source: source))
            serial += 1
        }

        send()
        return removed
    }

    // A whole mode: bindings, blocks and its options.
    func unbind(mode name: String) {
        entries.removeAll { $0.address.mode == name }
        modes[name] = nil
        send()
    }

    // One binding, as bindings() returned it.
    func unbind(binding keys: String, run: KeyRun) throws -> Int {
        let address = try parse(keys)
        guard let i = entries.firstIndex(where: { $0.address == address && !$0.isBlock && matches($0.run, run) }) else { return 0 }

        entries.remove(at: i)
        send()
        return 1
    }

    private func matches(_ have: KeyRun?, _ want: KeyRun?) -> Bool {
        guard let want else { return true }
        guard let have else { return false }

        switch (have, want) {
        case (.function(let a), .function(let b)): return same(a, b)
        case (.action(let a, _), .action(let b, _)): return a == b
        default: return false
        }
    }

    // MARK: Listing

    // Rex's rex.bindings: key, mode, action or fn, args, source; oldest first.
    func bindings(key: String?, mode: String?, action: String?) -> [[String: Any]] {
        entries.filter { !$0.isBlock }.compactMap { e in
            if let key, e.keys != key, e.address.sequence.description != key { return nil }
            if let mode, e.address.mode != mode { return nil }

            var row: [String: Any] = ["key": e.address.sequence.description, "source": e.source]
            if let m = e.address.mode { row["mode"] = m }

            switch e.run {
            case .action(let name, let args)?:
                if let action, action != name { return nil }

                row["action"] = name
                if let args { row["args"] = args }
            case .function(let f)?:
                if action != nil { return nil }

                row["fn"] = f
            case nil:
                return nil
            }

            return row
        }
    }

    // Declared or merely bound into: both make a mode.
    func modeList() -> [[String: Any]] {
        var seen = modes
        for e in entries {
            guard let m = e.address.mode, seen[m] == nil else { continue }

            seen[m] = Mode(exclusive: false, source: e.source)
        }

        return seen.sorted { $0.key < $1.key }.map {
            ["name": $0.key, "exclusive": $0.value.exclusive, "source": $0.value.source]
        }
    }

    // MARK: Canvas

    // Everything again: a canvas that came up after the script has none of it.
    func resend() {
        send()
    }

    private func send() {
        let list = entries.map { e -> KeymapWire.Entry in
            var w = KeymapWire.Entry(serial: e.serial, keys: e.keys)
            switch e.run {
            case .action(let name, let args)?:
                w.action = name
                w.args = args.flatMap { try? ScriptJSON.encode($0) }
            case .function?:
                w.fn = e.fnID
            case nil:
                w.block = true
            }

            return w
        }

        publish(KeymapWire(token: token, entries: list, modes: modes.mapValues(\.exclusive)))
    }

    // The canvas says one of ours was hit: what to run, and what to show it.
    func firing(_ f: [String: Any]) -> KeyFiring? {
        guard f["token"] as? String == token else { return nil }

        var ev = [String: Any]()
        ev["keybinding"] = f["key"]
        if let prefix = f["prefix"] as? [Any], !prefix.isEmpty { ev["prefix"] = prefix }
        if let mode = f["mode"] as? String { ev["mode"] = mode }

        let label = f["key"] as? String ?? "key"
        let req = f["req"] as? String

        if let id = f["fn"] as? Int {
            guard let hit = entries.first(where: { $0.fnID == id }), case .function(let fn)? = hit.run else { return nil }

            return KeyFiring(run: .function(fn), fields: ev, label: label, req: req)
        }

        guard let name = f["action"] as? String else { return nil }

        let args = (f["args"] as? String).flatMap { try? ScriptJSON.decode($0) } as? [String: Any]
        return KeyFiring(run: .action(name, args: args), fields: ev, label: label, req: nil)
    }
}
