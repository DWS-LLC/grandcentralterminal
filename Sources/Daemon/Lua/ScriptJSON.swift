// JSON text <-> Swift values, for gct.json, `--args` and printed results.
// Hand-rolled because JSONSerialization hands back NSNumber, which can't tell
// 1 from true on every platform; scripts need ints, bools and null kept apart.
//
//   {"n": 1, "ok": true, "x": null}  ◄──►  [String: Any] with Int, Bool, NSNull

import Foundation

enum ScriptJSON {
    enum Style {
        case compact, indented
    }

    private static let maxDepth = 64
    private static let integralLimit = 1e15

    // MARK: Decode

    static func decode(_ text: String) throws -> Any? {
        var p = Parser(bytes: Array(text.utf8))
        let v = try p.value(depth: 0)

        p.skipSpace()
        guard p.atEnd else { throw ScriptError("json: trailing characters at \(p.pos)") }

        return v is NSNull ? nil : v
    }

    private struct Parser {
        let bytes: [UInt8]
        var pos = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { pos >= bytes.count }

        mutating func skipSpace() {
            while pos < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[pos]) { pos += 1 }
        }

        private func fail(_ what: String) -> ScriptError {
            ScriptError("json: \(what) at \(pos)")
        }

        mutating func value(depth: Int) throws -> Any {
            guard depth < ScriptJSON.maxDepth else { throw fail("nested too deep") }

            skipSpace()
            guard pos < bytes.count else { throw fail("unexpected end") }

            switch bytes[pos] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return try string()
            case UInt8(ascii: "t"): return try word("true", true)
            case UInt8(ascii: "f"): return try word("false", false)
            case UInt8(ascii: "n"): return try word("null", NSNull())
            default: return try number()
            }
        }

        private mutating func word(_ w: String, _ v: Any) throws -> Any {
            let n = Array(w.utf8)
            guard bytes.count - pos >= n.count, Array(bytes[pos..<pos + n.count]) == n else {
                throw fail("unexpected character")
            }

            pos += n.count
            return v
        }

        private mutating func number() throws -> Any {
            let start = pos
            while pos < bytes.count, "+-0123456789.eE".utf8.contains(bytes[pos]) { pos += 1 }

            let text = String(decoding: bytes[start..<pos], as: UTF8.self)
            if let i = Int(text) { return i }
            guard let d = Double(text), d.isFinite else { throw fail("bad number") }

            return d
        }

        private mutating func string() throws -> String {
            pos += 1
            var out = [UInt8]()

            while pos < bytes.count {
                let c = bytes[pos]
                pos += 1

                if c == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
                guard c == UInt8(ascii: "\\") else { out.append(c); continue }

                guard pos < bytes.count else { break }

                let e = bytes[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"): out.append(contentsOf: try unicode())
                default: out.append(e)
                }
            }

            throw fail("unterminated string")
        }

        private mutating func hex4() throws -> UInt32 {
            guard bytes.count - pos >= 4,
                  let n = UInt32(String(decoding: bytes[pos..<pos + 4], as: UTF8.self), radix: 16) else {
                throw fail("bad \\u escape")
            }

            pos += 4
            return n
        }

        // \uXXXX, joining a surrogate pair into one scalar.
        private mutating func unicode() throws -> [UInt8] {
            var n = try hex4()
            let isHigh = (0xD800..<0xDC00).contains(n)

            if isHigh, bytes.count - pos >= 2, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") {
                pos += 2
                let low = try hex4()
                n = 0x10000 + ((n - 0xD800) << 10) + (low &- 0xDC00)
            }

            return Array(String(Unicode.Scalar(n) ?? "\u{FFFD}").utf8)
        }

        private mutating func array(depth: Int) throws -> Any {
            pos += 1
            var out = [Any]()

            skipSpace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return out }

            while true {
                out.append(try value(depth: depth + 1))
                skipSpace()

                guard pos < bytes.count else { throw fail("unterminated array") }

                let c = bytes[pos]
                pos += 1
                if c == UInt8(ascii: "]") { return out }
                guard c == UInt8(ascii: ",") else { throw fail("expected , or ]") }
            }
        }

        private mutating func object(depth: Int) throws -> Any {
            pos += 1
            var out = [String: Any]()

            skipSpace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return out }

            while true {
                skipSpace()
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw fail("expected a key") }

                let key = try string()
                skipSpace()
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw fail("expected :") }

                pos += 1
                let item = try value(depth: depth + 1)
                if !(item is NSNull) { out[key] = item }

                skipSpace()
                guard pos < bytes.count else { throw fail("unterminated object") }

                let c = bytes[pos]
                pos += 1
                if c == UInt8(ascii: "}") { return out }
                guard c == UInt8(ascii: ",") else { throw fail("expected , or }") }
            }
        }
    }

    // MARK: Encode

    static func encode(_ v: Any?, style: Style = .compact) throws -> String {
        var out = ""
        try write(v, into: &out, indent: style == .indented ? 0 : nil)
        return out
    }

    private static func write(_ v: Any?, into out: inout String, indent: Int?, depth: Int = 0) throws {
        guard depth < maxDepth else { throw ScriptError("json: nested too deep") }

        switch v {
        case nil, is NSNull:
            out += "null"
        case let b as Bool:
            out += b ? "true" : "false"
        case let n as any BinaryInteger:
            out += String(n)
        case let d as Double:
            out += try number(d)
        case let s as String:
            quote(s, into: &out)
        case is Data:
            throw ScriptError("json: binary string can't be encoded")
        case let a as [Any]:
            try write(items: a.map { ($0, nil) }, open: "[", close: "]", into: &out, indent: indent, depth: depth)
        case let m as [String: Any]:
            let rows = m.keys.sorted().map { (m[$0], $0 as String?) }
            try write(items: rows, open: "{", close: "}", into: &out, indent: indent, depth: depth)
        default:
            throw ScriptError("json: can't encode \(type(of: v))")
        }
    }

    private static func number(_ d: Double) throws -> String {
        guard d.isFinite else { throw ScriptError("json: can't encode nan or inf") }
        guard d == d.rounded(), abs(d) < integralLimit else { return String(d) }

        return String(Int(d))
    }

    // Arrays and objects share their layout; a key makes a row an object field.
    private static func write(items: [(Any?, String?)], open: String, close: String,
                              into out: inout String, indent: Int?, depth: Int) throws {
        guard !items.isEmpty else {
            out += open + close
            return
        }

        let step = indent.map { String(repeating: "  ", count: $0 + 1) }
        out += open

        for (i, (item, key)) in items.enumerated() {
            if i > 0 { out += "," }
            if let step { out += "\n" + step }
            if let key {
                quote(key, into: &out)
                out += indent == nil ? ":" : ": "
            }
            try write(item, into: &out, indent: indent.map { $0 + 1 }, depth: depth + 1)
        }

        if let indent { out += "\n" + String(repeating: "  ", count: indent) }
        out += close
    }

    private static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                guard u.value < 0x20 else { out.unicodeScalars.append(u); continue }

                out += String(format: "\\u%04x", u.value)
            }
        }
        out += "\""
    }
}
