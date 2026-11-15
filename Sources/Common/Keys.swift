// Key notation shared by the canvas (which matches real keys) and gctd (which
// checks what a script binds): strokes, sequences, and the engine that walks
// them. No AppKit, so it builds and tests anywhere.
//
//   "ctrl+b>c"   stroke ctrl+b, then stroke c
//   "resize/h"   stroke h, but only while the resize mode is active
//
//   key ─► KeyEngine.feed ─► pass      the terminal gets it
//                            consumed  eaten (a prefix, a mode change, a swallow)
//                            fire      run a target: action, or script function

import Foundation

private let sequenceSeparator: Character = ">"
private let modeSeparator: Character = "/"
private let plusKey = "+"
private let maxSequence = 8
private let maxModeName = 32
private let escapeKey = "escape"
private let enterModeAction = "client.mode.enter"
private let exitModeAction = "client.mode.exit"
private let exitAllAction = "client.mode.exit_all"

private let modifierNames: [String: KeyStroke.Mods] = [
    "cmd": .cmd, "super": .cmd, "ctrl": .ctrl, "control": .ctrl,
    "alt": .alt, "opt": .alt, "option": .alt, "shift": .shift,
]

private let keyAliases = [
    "return": "enter", "esc": escapeKey, "backspace": "delete",
]

private let namedKeys: Set<String> = [
    "space", "tab", "enter", escapeKey, "delete", "left", "right", "up", "down",
    "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
]

// MARK: - Strokes

public struct KeyStroke: Hashable, Sendable, CustomStringConvertible {
    public struct Mods: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let cmd = Mods(rawValue: 1)
        public static let ctrl = Mods(rawValue: 2)
        public static let alt = Mods(rawValue: 4)
        public static let shift = Mods(rawValue: 8)
    }

    public let mods: Mods
    public let key: String

    // The canvas builds these from NSEvents: the key is already canonical.
    public init(mods: Mods, key: String) {
        self.mods = mods
        self.key = key
    }

    // "cmd+shift+k", "ctrl+space", "alt+left", "cmd++" (the plus key).
    public init?(_ spec: String) {
        let text = spec.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }

        // A bare "+" or a trailing one is the plus key itself, not a separator.
        var parts: [String]
        if text == plusKey {
            parts = [plusKey]
        } else if text.hasSuffix(plusKey + plusKey) {
            parts = text.dropLast(2).split(separator: "+", omittingEmptySubsequences: false).map(String.init) + [plusKey]
        } else {
            parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        }

        guard let name = parts.popLast(), let key = Self.canonical(name) else { return nil }

        var mods = Mods()
        for part in parts {
            guard let m = modifierNames[part] else { return nil }

            mods.insert(m)
        }

        self.init(mods: mods, key: key)
    }

    // A named key (aliases folded), or one character; nil for anything else.
    public static func canonical(_ name: String) -> String? {
        let lower = name.lowercased()
        if let alias = keyAliases[lower] { return alias }
        if namedKeys.contains(lower) { return lower }

        return lower.count == 1 ? lower : nil
    }

    public var isEscape: Bool { mods.isEmpty && key == escapeKey }

    // cmd+ctrl+alt+shift+key, always in that order.
    public var description: String {
        var out = ""
        for (name, m) in [("cmd", Mods.cmd), ("ctrl", .ctrl), ("alt", .alt), ("shift", .shift)] where mods.contains(m) {
            out += name + "+"
        }

        return out + key
    }
}

// MARK: - Sequences and addresses

public struct KeySequence: Hashable, Sendable, CustomStringConvertible {
    public let strokes: [KeyStroke]

    public init(_ strokes: [KeyStroke]) {
        self.strokes = strokes
    }

    // "ctrl+b>c": strokes joined by ">". The > key itself is shift+period.
    public init?(_ spec: String) {
        let parts = spec.split(separator: sequenceSeparator, omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= maxSequence else { return nil }

        var strokes = [KeyStroke]()
        for part in parts {
            guard let s = KeyStroke(String(part)) else { return nil }

            strokes.append(s)
        }

        self.init(strokes)
    }

    public var description: String {
        strokes.map(\.description).joined(separator: String(sequenceSeparator))
    }
}

// A binding's address: "resize/h" is key h inside the resize mode; no
// prefix means the normal layer.
public struct KeyAddress: Hashable, Sendable {
    public let mode: String?
    public let sequence: KeySequence

    public init?(_ spec: String) {
        var mode: String?
        var rest = Substring(spec)

        // "cmd+/" and "/" are keys, not modes: a mode name has no + and isn't empty.
        if let slash = spec.firstIndex(of: modeSeparator) {
            let head = String(spec[..<slash])
            if Self.validMode(head) {
                mode = head
                rest = spec[spec.index(after: slash)...]
            }
        }

        guard let seq = KeySequence(String(rest)) else { return nil }

        self.mode = mode
        sequence = seq
    }

    // Lowercase letters, digits, underscores and hyphens.
    public static func validMode(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxModeName else { return false }

        return name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

// MARK: - Wire

// One script's whole keymap, sent in full on every change so the canvas never
// has to patch: an empty one drops the script's bindings.
public struct KeymapWire: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var serial: Int
        public var keys: String
        public var action: String?
        public var args: String?
        public var fn: Int?
        public var block: Bool?

        public init(serial: Int, keys: String, action: String? = nil, args: String? = nil,
                    fn: Int? = nil, block: Bool? = nil) {
            self.serial = serial; self.keys = keys; self.action = action
            self.args = args; self.fn = fn; self.block = block
        }
    }

    public var token: String
    public var entries: [Entry]
    // Declared modes: name -> exclusive.
    public var modes: [String: Bool]

    public init(token: String, entries: [Entry] = [], modes: [String: Bool] = [:]) {
        self.token = token; self.entries = entries; self.modes = modes
    }

    public var isEmpty: Bool { entries.isEmpty && modes.isEmpty }
}

// MARK: - Engine

// A script answering a key it was told about: handled keys stay eaten, the
// rest go on to the terminal. `req` is the id the canvas put on the event.
public struct KeyReply: Codable, Sendable {
    public var token: String
    public var req: String
    public var handled: Bool

    public init(token: String, req: String, handled: Bool) {
        self.token = token; self.req = req; self.handled = handled
    }
}

public enum KeyTarget: Equatable, Sendable {
    case action(String, args: String?)
    case function(Int)
    case enter(mode: String, once: Bool)
    case exit
    case exitAll
    // Unbound on purpose: the key goes to the terminal, bound elsewhere or not.
    case block

    init?(_ e: KeymapWire.Entry) {
        if e.block == true {
            self = .block
            return
        }
        if let fn = e.fn {
            self = .function(fn)
            return
        }
        guard let name = e.action else { return nil }

        switch name {
        case exitModeAction:
            self = .exit
        case exitAllAction:
            self = .exitAll
        case enterModeAction:
            let args = e.args.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            guard let mode = args?["name"] as? String else { return nil }

            self = .enter(mode: mode, once: args?["once"] as? Bool ?? false)
        default:
            self = .action(name, args: e.args)
        }
    }
}

// What a pressed key asks for, once the engine has seen it.
public struct KeyFire: Equatable, Sendable {
    public var target: KeyTarget
    public var source: String
    public var key: KeyStroke
    public var prefix: [KeyStroke]
    public var mode: String?
}

public enum KeyOutcome: Equatable, Sendable {
    case pass
    case consumed
    case fire(KeyFire)
}

public final class KeyEngine {
    // The config's own bindings: always the oldest, so scripts override them.
    public static let configSource = "config"

    private struct Rank: Comparable {
        var source: Int
        var serial: Int

        static func < (a: Rank, b: Rank) -> Bool {
            (a.source, a.serial) < (b.source, b.serial)
        }
    }

    private struct Binding {
        var rank: Rank
        var source: String
        var mode: String?
        var strokes: [KeyStroke]
        var target: KeyTarget
    }

    private struct Pending {
        var mode: String?
        var strokes: [KeyStroke]
    }

    private struct Active {
        var name: String
        var once: Bool
    }

    private enum Match {
        case none
        case hit(Binding)
        case prefix
    }

    private var bindings = [Binding]()
    private var declared = [String: [String: Bool]]()
    private var order = [String: Int]()
    private var nextOrder = 1
    private var active = [Active]()
    private var pending: Pending?

    public init() {
        order[Self.configSource] = 0
    }

    // MARK: Keymaps

    // Swap one source's whole keymap. Bad entries are skipped: the sender
    // already checked them, this is the canvas guarding itself.
    public func replace(_ wire: KeymapWire) {
        if order[wire.token] == nil {
            order[wire.token] = nextOrder
            nextOrder += 1
        }

        let rank = order[wire.token] ?? 0
        bindings.removeAll { $0.source == wire.token }
        for e in wire.entries {
            guard let addr = KeyAddress(e.keys), let target = KeyTarget(e) else { continue }

            bindings.append(Binding(rank: Rank(source: rank, serial: e.serial), source: wire.token,
                                    mode: addr.mode, strokes: addr.sequence.strokes, target: target))
        }

        declared[wire.token] = wire.modes
        settle()
    }

    public func remove(source: String) {
        bindings.removeAll { $0.source == source }
        declared[source] = nil
        order[source] = nil
        settle()
    }

    // A mode nobody binds or declares any more can't trap the keyboard.
    private func settle() {
        active.removeAll { !modeExists($0.name) }
        if let p = pending, p.mode.map({ !modeExists($0) }) ?? false { pending = nil }
    }

    private func modeExists(_ name: String) -> Bool {
        bindings.contains { $0.mode == name } || declared.values.contains { $0[name] != nil }
    }

    // The newest source that declared it decides.
    private func exclusive(_ name: String) -> Bool {
        let newest = declared.filter { $0.value[name] != nil }.max { (order[$0.key] ?? 0) < (order[$1.key] ?? 0) }
        return newest?.value[name] ?? false
    }

    // MARK: Keys

    public func feed(_ spec: String) -> KeyOutcome {
        guard let s = KeyStroke(spec) else { return .pass }

        return feed(s)
    }

    public func feed(_ s: KeyStroke) -> KeyOutcome {
        if let p = pending {
            return carryOn(p, s)
        }

        // Newest mode first; an exclusive one swallows what it doesn't bind.
        for (depth, mode) in active.reversed().enumerated() {
            switch find(mode: mode.name, prefix: [], s) {
            case .hit(let b):
                return resolve(b, prefix: [])
            case .prefix:
                pending = Pending(mode: mode.name, strokes: [s])
                return .consumed
            case .none:
                // Escape leaves the current mode unless the mode binds it.
                if depth == 0, s.isEscape {
                    active.removeLast()
                    return .consumed
                }
                if exclusive(mode.name) { return .consumed }
            }
        }

        switch find(mode: nil, prefix: [], s) {
        case .hit(let b):
            return resolve(b, prefix: [])
        case .prefix:
            pending = Pending(mode: nil, strokes: [s])
            return .consumed
        case .none:
            return .pass
        }
    }

    private func carryOn(_ p: Pending, _ s: KeyStroke) -> KeyOutcome {
        switch find(mode: p.mode, prefix: p.strokes, s) {
        case .hit(let b):
            pending = nil
            return resolve(b, prefix: p.strokes)
        case .prefix:
            pending = Pending(mode: p.mode, strokes: p.strokes + [s])
            return .consumed
        case .none:
            // Escape, or a key that goes nowhere: the sequence is over.
            pending = nil
            return .consumed
        }
    }

    // Among bindings in this layer that start with prefix + s, the newest
    // wins: a key runs an action or opens a sequence, never both.
    private func find(mode: String?, prefix: [KeyStroke], _ s: KeyStroke) -> Match {
        let want = prefix + [s]
        let hits = bindings.filter {
            $0.mode == mode && $0.strokes.count >= want.count && Array($0.strokes.prefix(want.count)) == want
        }

        guard let best = hits.max(by: { $0.rank < $1.rank }) else { return .none }

        return best.strokes.count == want.count ? .hit(best) : .prefix
    }

    private func resolve(_ b: Binding, prefix: [KeyStroke]) -> KeyOutcome {
        if b.target == .block { return .pass }

        // A once mode serves one shortcut, then leaves, before the shortcut runs.
        if let m = b.mode, let i = active.lastIndex(where: { $0.name == m && $0.once }) {
            active.remove(at: i)
        }

        switch b.target {
        case .enter(let mode, let once):
            guard modeExists(mode) else { return .consumed }

            active.removeAll { $0.name == mode }
            active.append(Active(name: mode, once: once))
            return .consumed
        case .exit:
            if !active.isEmpty { active.removeLast() }
            return .consumed
        case .exitAll:
            active.removeAll()
            return .consumed
        case .block:
            return .pass
        case .action, .function:
            let key = b.strokes.last ?? KeyStroke(mods: [], key: "")
            return .fire(KeyFire(target: b.target, source: b.source, key: key, prefix: prefix, mode: b.mode))
        }
    }

    // MARK: State

    // For a corner readout: the modes, then the keys typed so far.
    public var status: String? {
        let modes = active.map(\.name).joined(separator: " ")
        let typed = pending.map { $0.strokes.map(\.description).joined(separator: " ") + " …" } ?? ""
        let text = [modes, typed].filter { !$0.isEmpty }.joined(separator: "  ")
        return text.isEmpty ? nil : text
    }

    public var modeNames: [String] { active.map(\.name) }

    public var isPending: Bool { pending != nil }

    // The sequence is abandoned, as if Escape: its keys stay eaten.
    public func cancelPending() {
        pending = nil
    }

    public func reset() {
        active.removeAll()
        pending = nil
    }
}
