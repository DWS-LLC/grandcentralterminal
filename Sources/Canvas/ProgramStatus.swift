// OSC 7501 Program Status: canvas-side parse + per-pane record store.
//
// libghostty's embedded termio path drops program-status reports before
// they reach the app, so the canvas scans the daemon output stream itself
// (connOutput is the single funnel for every pane, local and remote) and
// renders the effective status right-aligned in the titlebar.
//
// Spec: https://www.superlogical.com/rex/docs/build/program-status

import Foundation
import Common

enum ProgramState: String, Equatable {
    case idle, working, done, blocked, error
}

enum ProgramBlockKind: String, Equatable {
    case permission, question, auth
}

struct ProgramRecord {
    var state: ProgramState
    var kind: ProgramBlockKind?
    var progress: Int?
    var id: String          // "" = root record
    var app: String?
    var title: String?
    var msg: String?
    var seq: UInt64         // update order: LRU eviction + recency tiebreak
}

final class ProgramStatusStore {
    struct Summary: Equatable {
        var state: ProgramState
        var text: String
    }

    struct IngestResult {
        var changed: Bool
        var queryReply: Bool
    }

    private static let esc: UInt8 = 0x1B
    private static let osc7501: [UInt8] = [0x5D, 0x37, 0x35, 0x30, 0x31, 0x3B]  // ] 7501 ;
    private static let osc133: [UInt8] = [0x5D, 0x31, 0x33, 0x33, 0x3B]         // ] 133 ;
    private static let maxReport = 4096       // spec: whole sequence limit
    private static let maxPending = 4300      // carry cap, a bit over maxReport
    private static let splitOpener = 8        // tail short enough to be a cut opener

    /// Fixed reply to the `OSC 7501 ; ?` support query.
    static let queryReply = Data([esc] + osc7501 + [0x3F, esc, 0x5C])

    private struct PaneState {
        var records = [String: ProgramRecord]()
        var carry = Data()       // unterminated tail: sequence split across chunks
        var seq: UInt64 = 0
        var last: Summary?
    }

    private var panes: [PaneID: PaneState] = [:]

    // MARK: - Ingest

    /// Scan output bytes for OSC 7501 reports/queries (plus OSC 133;A prompt
    /// markers and RIS for record lifetimes). The bytes pass through to the
    /// terminal untouched; only the store changes.
    /// Replayed history never triggers a query reply: it already happened.
    func ingest(_ data: Data, pane: PaneID, source: OutputSource) -> IngestResult {
        let idle = IngestResult(changed: false, queryReply: false)
        if data.isEmpty { return idle }

        // Hot path (cat, build logs): no ESC and nothing pending = nothing to do.
        let pending = panes[pane]?.carry.isEmpty == false
        if !pending, !data.contains(Self.esc) { return idle }

        var st = panes[pane] ?? PaneState()
        var buf = Data(data)  // zero-based: carry slices below index from 0
        if !st.carry.isEmpty {
            buf = st.carry + data
            st.carry.removeAll(keepingCapacity: false)
        }
        let before = st.last
        var reply = false
        buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let n = raw.count
            var i = 0
            while i < n {
                guard base[i] == Self.esc else { i += 1; continue }
                // Chunk tail that could be a split opener (or a lone
                // ESC): hold it for the next chunk instead of skipping.
                if n - i < Self.splitOpener {
                    let tail = (i..<n).map { base[$0] }
                    let p7501 = [Self.esc] + Self.osc7501
                    let p133 = [Self.esc] + Self.osc133
                    if p7501.prefix(tail.count).elementsEqual(tail)
                        || p133.prefix(tail.count).elementsEqual(tail)
                        || tail.count == 1 {
                        st.carry = buf[i..<n]
                        i = n
                        continue
                    }
                }
                // RIS (ESC c): full reset drops every record.
                if i + 1 < n, base[i + 1] == 0x63 {
                    st.records.removeAll()
                    i += 2
                    continue
                }
                if let digits = oscCode(base, n, at: i), digits == 4 || digits == 3 {
                    let is7501 = digits == 4
                    let bodyStart = i + 2 + digits + 1
                    switch findTerm(base, n, from: bodyStart) {
                    case .partial:
                        // No terminator yet: hold the tail for the next chunk.
                        // Over the 4096 limit it can never complete: drop it.
                        st.carry = n - i > Self.maxPending ? Data() : buf[i..<n]
                        i = n
                    case .broken(let at):
                        i = at
                    case .done(let br, let end):
                        if end - i > Self.maxReport {
                            i = end  // over-limit report: discarded whole
                            continue
                        }
                        if is7501 {
                            if br.count == 1, base[br.lowerBound] == 0x3F {
                                reply = source == .live  // support query
                            } else {
                                applyReport(base, br, &st)
                            }
                        } else if isPromptStart(base, br) {
                            // New shell prompt: working/blocked are over.
                            // done/error survive; idle may drop.
                            st.records = st.records.filter {
                                $0.value.state != .working && $0.value.state != .blocked
                            }
                        }
                        i = end
                    }
                    continue
                }
                i += 1
            }
        }
        st.last = summarize(st)
        panes[pane] = st
        return IngestResult(changed: st.last != before, queryReply: reply)
    }

    /// The user typed into the pane: done/error served their purpose.
    /// Returns true when the visible summary changed.
    @discardableResult
    func noteInput(_ pane: PaneID) -> Bool {
        guard var st = panes[pane],
              st.records.values.contains(where: { $0.state == .done || $0.state == .error })
        else { return false }
        let before = st.last
        st.records = st.records.filter {
            $0.value.state != .done && $0.value.state != .error
        }
        st.last = summarize(st)
        panes[pane] = st
        return st.last != before
    }

    func summary(for pane: PaneID) -> Summary? {
        panes[pane]?.last
    }

    func remove(_ pane: PaneID) {
        panes.removeValue(forKey: pane)
    }

    // MARK: - Scanning

    private enum Term {
        case done(body: Range<Int>, end: Int)
        case partial
        case broken(at: Int)  // bare ESC inside: restart from there
    }

    /// If bytes at i are `ESC ] <3-4 digits> ;`, return the digit count.
    private func oscCode(_ base: UnsafePointer<UInt8>, _ n: Int, at i: Int) -> Int? {
        guard i + 3 < n, base[i + 1] == 0x5D else { return nil }
        var j = i + 2
        while j < n, base[j] >= 0x30, base[j] <= 0x39 { j += 1 }
        let digits = j - (i + 2)
        guard (digits == 3 || digits == 4), j < n, base[j] == 0x3B else { return nil }
        // Only 7501 and 133 matter here; anything else isn't ours.
        if digits == 4 {
            guard base[i+2] == 0x37, base[i+3] == 0x35,
                  base[i+4] == 0x30, base[i+5] == 0x31 else { return nil }
        } else {
            guard base[i+2] == 0x31, base[i+3] == 0x33, base[i+4] == 0x33 else { return nil }
        }
        return digits
    }

    private func findTerm(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> Term {
        var j = from
        while j < n {
            let b = base[j]
            if b == 0x07 { return .done(body: from..<j, end: j + 1) }
            if b == 0x1B {
                if j + 1 < n, base[j + 1] == 0x5C {
                    return .done(body: from..<j, end: j + 2)
                }
                if j + 1 >= n { return .partial }  // trailing ESC: split ST?
                return .broken(at: j)
            }
            j += 1
        }
        return .partial
    }

    /// OSC 133;A (prompt start): body "A" or "A;...".
    private func isPromptStart(_ base: UnsafePointer<UInt8>, _ br: Range<Int>) -> Bool {
        guard !br.isEmpty, base[br.lowerBound] == 0x41 else { return false }
        return br.count == 1 || base[br.lowerBound + 1] == 0x3B
    }

    // MARK: - Reports

    private static let valueSet: Set<UInt8> = {
        var s = Set<UInt8>()
        for b in 0x30...0x39 { s.insert(UInt8(b)) }  // 0-9
        for b in 0x41...0x5A { s.insert(UInt8(b)) }  // A-Z
        for b in 0x61...0x7A { s.insert(UInt8(b)) }  // a-z
        for c: UInt8 in [0x5F, 0x2E, 0x2C, 0x2B, 0x2F, 0x3D, 0x2D] { s.insert(c) }  // _.,+/=-
        return s
    }()

    private static let idSegSet: Set<UInt8> = {
        var s = Set<UInt8>()
        for b in 0x30...0x39 { s.insert(UInt8(b)) }
        for b in 0x41...0x5A { s.insert(UInt8(b)) }
        for b in 0x61...0x7A { s.insert(UInt8(b)) }
        for c: UInt8 in [0x5F, 0x2E, 0x2B, 0x2D] { s.insert(c) }  // _ . + -
        return s
    }()

    /// Parse + validate a report body, then apply it. Anything invalid
    /// ignores/discards per spec; every limit is checked before stored
    /// records are touched.
    private func applyReport(_ base: UnsafePointer<UInt8>, _ br: Range<Int>,
                             _ st: inout PaneState) {
        var pairs = [String: String]()
        var p = br.lowerBound
        while p < br.upperBound {
            var q = p
            while q < br.upperBound, base[q] != 0x3A { q += 1 }  // split on ":"
            // Split pair on the first "=".
            var eq: Int? = nil
            var k = p
            while k < q {
                if base[k] == 0x3D { eq = k; break }
                k += 1
            }
            if let e = eq {
                var ks = p
                while ks < e, base[ks] == 0x20 || base[ks] == 0x09 { ks += 1 }
                var ke = e
                while ke > ks, base[ke - 1] == 0x20 || base[ke - 1] == 0x09 { ke -= 1 }
                var vs = e + 1
                while vs < q, base[vs] == 0x20 || base[vs] == 0x09 { vs += 1 }
                var ve = q
                while ve > vs, base[ve - 1] == 0x20 || base[ve - 1] == 0x09 { ve -= 1 }
                if ks < ke {
                    let keyLen = ke - ks
                    if keyLen > 16 { return }  // limit: discard whole report
                    var keyOK = true
                    for t in ks..<ke where base[t] < 0x61 || base[t] > 0x7A {
                        keyOK = false  // not [a-z]+: malformed pair, skip it
                        break
                    }
                    var valOK = true
                    for t in vs..<ve where !Self.valueSet.contains(base[t]) {
                        valOK = false
                        break
                    }
                    if keyOK, valOK {
                        let key = String(bytes: (ks..<ke).map { base[$0] }, encoding: .utf8)!
                        let val = String(bytes: (vs..<ve).map { base[$0] }, encoding: .utf8)!
                        pairs[key] = val  // last wins
                    }
                }
            }
            p = q + 1
        }

        guard let stateRaw = pairs["state"] else { return }
        if stateRaw == "clear" {
            // clear is not a state: remove the record + everything beneath it.
            if let id = pairs["id"] {
                guard Self.validID(id) else { return }
                st.records = st.records.filter { $0.key != id && !$0.key.hasPrefix(id + "/") }
            } else {
                st.records.removeAll()
            }
            return
        }
        guard let state = ProgramState(rawValue: stateRaw) else { return }

        let idKey = pairs["id"] ?? ""
        if pairs["id"] != nil, !Self.validID(idKey) { return }

        var kind: ProgramBlockKind? = nil
        if state == .blocked, let k = pairs["kind"] {
            kind = ProgramBlockKind(rawValue: k)  // unrecognized = absent
        }
        var progress: Int? = nil
        if state == .working || state == .blocked,
           let pr = pairs["progress"], !pr.isEmpty,
           pr.allSatisfy({ $0.isNumber }), let v = Int(pr), v <= 100 {
            progress = v
        }
        var app: String? = nil
        if let a = pairs["app"], !a.isEmpty, a.count <= 32,
           a.allSatisfy({ Self.idSegSet.contains($0.asciiValue ?? 0) }) {
            app = a
        }
        var title: String? = nil
        if let t = pairs["title"] {
            guard let d = Self.decodeText(t, encMax: 256, decMax: 192) else { return }
            title = d
        }
        var msg: String? = nil
        if let m = pairs["msg"] {
            guard let d = Self.decodeText(m, encMax: 2732, decMax: 2048) else { return }
            msg = d
        }

        // Every report replaces its record completely.
        st.seq += 1
        st.records[idKey] = ProgramRecord(state: state, kind: kind, progress: progress,
                                          id: idKey, app: app, title: title, msg: msg,
                                          seq: st.seq)
        if st.records.count > 256 {
            // Past the cap: drop the least-recently-updated record.
            if let oldest = st.records.min(by: { $0.value.seq < $1.value.seq })?.key {
                st.records.removeValue(forKey: oldest)
            }
        }
    }

    private static func validID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        let segs = id.split(separator: "/", omittingEmptySubsequences: false)
        guard segs.count <= 8 else { return false }
        for s in segs {
            guard s.count >= 1, s.count <= 32,
                  s.allSatisfy({ idSegSet.contains($0.asciiValue ?? 0) }) else { return false }
        }
        return true
    }

    /// Base64 of UTF-8, padding optional; rejects control characters.
    private static func decodeText(_ enc: String, encMax: Int, decMax: Int) -> String? {
        guard enc.count <= encMax else { return nil }
        var padded = enc
        switch padded.count % 4 {
        case 2: padded += "=="
        case 3: padded += "="
        case 0: break
        default: return nil
        }
        guard let data = Data(base64Encoded: padded, options: []),
              data.count <= decMax,
              let text = String(data: data, encoding: .utf8) else { return nil }
        for sc in text.unicodeScalars {
            let v = sc.value
            if v < 0x20 || (v >= 0x7F && v <= 0x9F) { return nil }
        }
        return text
    }

    // MARK: - Summary

    private func appInheriting(_ rec: ProgramRecord, _ records: [String: ProgramRecord]) -> String? {
        if let a = rec.app { return a }
        var path = rec.id
        while let slash = path.lastIndex(of: "/") {
            path = String(path[..<slash])
            if let a = records[path]?.app { return a }
        }
        return records[""]?.app
    }

    private func summarize(_ st: PaneState) -> Summary? {
        let live = st.records.values.filter { $0.state != .idle }
        guard !live.isEmpty else { return nil }
        func rank(_ s: ProgramState) -> Int {
            switch s {
            case .blocked: return 0
            case .working: return 1
            case .error: return 2
            case .done: return 3
            case .idle: return 4
            }
        }
        var best = live.first!
        for r in live
        where rank(r.state) < rank(best.state)
                || (r.state == best.state && r.seq > best.seq) {
            best = r
        }
        let core: String
        if let m = best.msg, !m.isEmpty {
            core = (best.title != nil && !best.title!.isEmpty) ? "\(best.title!): \(m)" : m
        } else if let t = best.title, !t.isEmpty {
            core = t
        } else if best.state == .blocked, let k = best.kind {
            core = k.rawValue
        } else {
            core = appInheriting(best, st.records) ?? best.state.rawValue
        }
        let head: String
        switch best.state {
        case .working:
            head = best.progress != nil ? "◌ \(best.progress!)%" : "◌"
        case .blocked: head = "▲"
        case .done: head = "✓"
        case .error: head = "✕"
        case .idle: head = ""
        }
        return Summary(state: best.state, text: "\(head) \(Self.display(core))")
    }

    /// Display-sanitize: strip bidi overrides/invisibles (untrusted program
    /// input shown outside the grid), cap length.
    private static func display(_ s: String) -> String {
        let banned: Set<Unicode.Scalar> = [
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{200E}", "\u{200F}", "\u{061C}", "\u{FEFF}", "\u{00AD}",
        ]
        let clean = String(s.unicodeScalars.filter { !banned.contains($0) })
        return clean.count > 120 ? String(clean.prefix(119)) + "…" : clean
    }
}
