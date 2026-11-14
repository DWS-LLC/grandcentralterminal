// Minimal TOML shared by the canvas config and the daemon's peer hosts.

import Foundation

// Just enough TOML for this schema: [tables], `key = value`, basic/literal
// strings, bare tokens (numbers, booleans, enums), and # comments.
public enum TOML {
    // section name -> key -> raw value token. Root keys live under "".
    public static func parse(_ text: String) -> [String: [String: String]] {
        var tables: [String: [String: String]] = ["": [:]]
        var section = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { continue }
                section = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                if tables[section] == nil { tables[section] = [:] }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else { continue }
            if let value = parseValue(String(line[line.index(after: eq)...])) {
                tables[section]?[key] = value
            }
        }
        return tables
    }

    // Cut at the first # that isn't inside a quoted string.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for (i, c) in line.enumerated() {
            if escaped { escaped = false; continue }
            if let q = quote {
                if c == "\\" { escaped = true }
                else if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" {
                return String(line[..<line.index(line.startIndex, offsetBy: i)])
            }
        }
        return line
    }

    private static func parseValue(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        if v.hasPrefix("\"") { return basicString(v) }
        if v.hasPrefix("'") {
            guard let end = v.dropFirst().firstIndex(of: "'") else { return nil }
            return String(v[v.index(after: v.startIndex)..<end])
        }
        // Bare token: number, boolean, or enum word.
        let token = v.prefix { !$0.isWhitespace }
        return token.isEmpty ? nil : String(token)
    }

    // Basic string with the common escapes (\n \t \r \" \\ \uXXXX).
    private static func basicString(_ v: String) -> String? {
        guard let end = closingQuote(v) else { return nil }
        let body = String(v[v.index(after: v.startIndex)..<end])
        var out = ""
        var it = body.makeIterator()
        while let c = it.next() {
            if c != "\\" { out.append(c); continue }
            guard let e = it.next() else { return nil }
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\"", "\\": out.append(e)
            case "u":
                var hex = ""
                for _ in 0..<4 { if let h = it.next() { hex.append(h) } }
                if let cp = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(cp) {
                    out.unicodeScalars.append(scalar)
                }
            default: return nil
            }
        }
        return out
    }

    private static func closingQuote(_ v: String) -> String.Index? {
        var i = v.index(after: v.startIndex)
        while i < v.endIndex {
            if v[i] == "\\" {
                i = v.index(i, offsetBy: 2, limitedBy: v.endIndex) ?? v.endIndex
                continue
            }
            if v[i] == "\"" { return i }
            i = v.index(after: i)
        }
        return nil
    }
}
