// The command palette's data: what a script publishes, and how a typed query
// ranks it.
//
//   gct.action{title=..} ─► PaletteWire ─► daemon ─► canvas ─► the palette list
//   a pick ─► state.key (token, action) ─► the script runs the action
//
// Like a keymap, a script sends its whole list on every change and the daemon
// takes it down when the script goes. Pure logic: tested without a canvas.

import Foundation

// One thing an action asks for before it runs: `args = { count = "integer", note = "string?" }`.
// The palette asks for each in turn and hands the script a table of the answers.
public struct PaletteArg: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case text = "string"
        case number
        case integer
        case boolean
    }

    // What the answer was typed as, ready for JSON.
    public enum Value: Sendable, Equatable {
        case text(String)
        case number(Double)
        case integer(Int)
        case boolean(Bool)

        public var json: Any {
            switch self {
            case .text(let v): return v
            case .number(let v): return v
            case .integer(let v): return v
            case .boolean(let v): return v
            }
        }
    }

    private static let optionalMark = "?"
    private static let kinds: [String: Kind] = [
        "string": .text, "text": .text,
        "number": .number, "float": .number, "double": .number,
        "integer": .integer, "int": .integer,
        "boolean": .boolean, "bool": .boolean,
    ]
    private static let yes: Set<String> = ["true", "yes", "y", "on", "1"]
    private static let no: Set<String> = ["false", "no", "n", "off", "0"]

    public var name: String
    public var kind: Kind
    // A blank answer leaves it out.
    public var optional: Bool

    public init(name: String, kind: Kind, optional: Bool = false) {
        self.name = name; self.kind = kind; self.optional = optional
    }

    // Rex's spelling: "string", "integer?"... A kind we don't know is text, so a
    // script written for Rex still loads.
    public init(name: String, spec: String) {
        let optional = spec.hasSuffix(Self.optionalMark)
        let word = optional ? String(spec.dropLast(Self.optionalMark.count)) : spec
        self.init(name: name, kind: Self.kinds[word.lowercased()] ?? .text, optional: optional)
    }

    // What to tell the person typing: "a whole number", "yes or no".
    public var hint: String {
        switch kind {
        case .text: return "text"
        case .number: return "a number"
        case .integer: return "a whole number"
        case .boolean: return "yes or no"
        }
    }

    // The typed answer, nil when it isn't one.
    public func value(of input: String) -> Value? {
        switch kind {
        case .text:
            return .text(input)
        case .number:
            guard let v = Double(input.trimmingCharacters(in: .whitespaces)), v.isFinite else { return nil }

            return .number(v)
        case .integer:
            return Int(input.trimmingCharacters(in: .whitespaces)).map(Value.integer)
        case .boolean:
            let word = input.trimmingCharacters(in: .whitespaces).lowercased()
            if Self.yes.contains(word) { return .boolean(true) }
            if Self.no.contains(word) { return .boolean(false) }

            return nil
        }
    }
}

public struct PaletteWire: Codable, Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        public var title: String
        public var description: String?
        public var category: String?
        public var keywords: String?
        // In the order they are asked; nil or empty: runs at once.
        public var args: [PaletteArg]?

        public init(name: String, title: String, description: String? = nil,
                    category: String? = nil, keywords: String? = nil, args: [PaletteArg]? = nil) {
            self.name = name; self.title = title; self.description = description
            self.category = category; self.keywords = keywords; self.args = args
        }
    }

    public var token: String
    public var entries: [Entry]

    public init(token: String, entries: [Entry] = []) {
        self.token = token; self.entries = entries
    }

    // An empty list drops the script's entries.
    public var isEmpty: Bool { entries.isEmpty }
}

// What a query is matched against.
public struct PaletteText: Sendable {
    public var title: String
    public var category: String
    public var keywords: String
    public var detail: String

    public init(title: String, category: String = "", keywords: String = "", detail: String = "") {
        self.title = title; self.category = category; self.keywords = keywords; self.detail = detail
    }
}

public enum PaletteRank {
    // How well one word of the query fits, best to worst: where it lands.
    private enum Weight {
        static let titlePrefix = 100
        static let titleWord = 80
        static let titleHas = 60
        static let category = 40
        static let keywords = 30
        static let detail = 10
        static let fuzzy = 5
    }

    // Indices of the items that match, best first; ties keep their order. Every
    // word of the query has to fit somewhere, so "leaf open" finds
    // "Leaf: Open Document…". An empty query keeps everything, in order.
    public static func order(_ items: [PaletteText], query: String) -> [Int] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return Array(items.indices) }

        var scored = [(index: Int, score: Int)]()
        for (i, item) in items.enumerated() {
            let each = words.map { score($0, in: item) }
            guard !each.contains(nil) else { continue }

            scored.append((i, each.compactMap { $0 }.reduce(0, +)))
        }

        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map(\.index)
    }

    private static func score(_ word: String, in item: PaletteText) -> Int? {
        let title = item.title.lowercased()
        if title.hasPrefix(word) { return Weight.titlePrefix }
        if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(word) }) {
            return Weight.titleWord
        }
        if title.contains(word) { return Weight.titleHas }
        if item.category.lowercased().contains(word) { return Weight.category }
        if item.keywords.lowercased().contains(word) { return Weight.keywords }
        if item.detail.lowercased().contains(word) { return Weight.detail }
        if isSubsequence(word, of: title) { return Weight.fuzzy }

        return nil
    }

    // "lod" is in "leaf: open document": its letters, in order.
    private static func isSubsequence(_ word: String, of text: String) -> Bool {
        var rest = word[...]
        for c in text {
            guard let next = rest.first else { return true }

            if c == next { rest.removeFirst() }
        }

        return rest.isEmpty
    }
}
