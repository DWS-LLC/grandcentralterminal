// `gctd lua`: parse the command line, connect, hand the script to the runtime.
//
//   gctd lua build.lua target=release     a file (ends in .lua or has a slash)
//   gctd lua -e 'print(gct.pane_id)'      inline
//   echo 'return 1+1' | gctd lua -        stdin

import Foundation
import Common

private let luaUsage = "lua <file.lua | -e code | -> [key=value]... [--args json|@file] [--json] [--for <span>] [--fail-fast] [--pane <pane>]"
private let luaSuffix = ".lua"
private let fileMark = "@"

// 3, 1.5, true and false keep their types; everything else is text.
private func inferred(_ raw: String) -> Any {
    if let i = Int(raw) { return i }
    if let d = Double(raw), d.isFinite { return d }
    if raw == "true" { return true }
    if raw == "false" { return false }

    return raw
}

private func jsonArgs(_ raw: String) -> [String: Any] {
    var text = raw
    if raw.hasPrefix(fileMark) {
        let path = String(raw.dropFirst(fileMark.count))
        guard let read = try? String(contentsOfFile: path, encoding: .utf8) else { die("--args: can't read \(path)") }

        text = read
    }

    do {
        guard let obj = try ScriptJSON.decode(text) as? [String: Any] else { bad("--args takes a JSON object") }

        return obj
    } catch let e as ScriptError {
        bad("--args: \(e.message)")
    } catch {
        bad("--args: \(error)")
    }
}

private struct LuaCall {
    var source: String?
    var chunk = "=(-e)"
    var words = [String]()
    var args = [String: Any]()
    var pretty = false
    var failFast = false
    var limit: TimeInterval?
    var pane: String?
}

private func parseLua(_ rest: [String]) -> LuaCall {
    var call = LuaCall()
    var extra: String?
    var i = 0

    func value(_ flag: String) -> String {
        i += 1
        guard i < rest.count else { bad("\(flag) needs a value") }

        return rest[i]
    }

    while i < rest.count {
        switch rest[i] {
        case "-e": call.source = value("-e")
        case "--json": call.pretty = true
        case "--fail-fast": call.failFast = true
        case "--args": extra = value("--args")
        case "--pane": call.pane = value("--pane")
        case "--for":
            guard let secs = Span.parse(value("--for")), secs > 0 else { bad("--for takes a span like 90s, 10m, 2h") }

            call.limit = secs
        default: call.words.append(rest[i])
        }
        i += 1
    }

    if call.source == nil {
        guard let script = call.words.first else { bad(luaUsage) }

        call.words.removeFirst()
        load(script, into: &call)
    }

    for w in call.words {
        guard let eq = w.firstIndex(of: "=") else { bad("expected key=value, got \(w)") }

        call.args[String(w[..<eq])] = inferred(String(w[w.index(after: eq)...]))
    }

    if let extra { call.args.merge(jsonArgs(extra)) { _, json in json } }
    return call
}

private func load(_ script: String, into call: inout LuaCall) {
    if script == "-" {
        call.source = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        call.chunk = "=(stdin)"
        return
    }

    guard script.hasSuffix(luaSuffix) || script.contains("/") else {
        bad("\(script) is not a script: a file ends in \(luaSuffix) or has a slash")
    }
    guard let text = try? String(contentsOfFile: script, encoding: .utf8) else { die("can't read \(script)", .notFound) }

    call.source = text
    call.chunk = "@" + script
}

func runLua(_ rest: [String]) -> Never {
    let call = parseLua(rest)
    guard let source = call.source else { bad(luaUsage) }

    let client = needClient()
    guard let session = ScriptSession(client: client) else { die("no reply from daemon") }

    if let ref = call.pane {
        do {
            session.home = try session.pane(ref).id
        } catch let e as ScriptError {
            missing("pane \(ref) (\(e.message))")
        } catch {
            die("\(error)")
        }
    }

    let loop = ScriptLoop(session: session)
    guard let runtime = ScriptRuntime(loop: loop, onError: call.failFast ? .exit : .carryOn) else { die("can't start Lua") }

    let status = runtime.run(source: source, name: call.chunk, args: call.args, output: call.pretty ? .indented : .compact,
                             limit: call.limit.map { Date().addingTimeInterval($0) })
    exit(status)
}
