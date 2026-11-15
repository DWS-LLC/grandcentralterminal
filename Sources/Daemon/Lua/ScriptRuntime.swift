// The `gct` table: ops, events, timers, exec and JSON wired into a Lua VM, and
// the run of one script from first line to exit status.
//
//   gctd lua script.lua ─► chunk runs ─► handlers/timers registered
//                                         │
//             idle loop ◄─────────────────┘  events ─► gct.on handlers
//                │                           clock  ─► gct.every / gct.after
//                └─ ends on gct.stop, --for, ^C, or the daemon going away
//
// Rex's conventions apply: a call that talks to GCT returns a result, or nil
// plus a message, and never raises. Misuse of the runtime itself (gct.on
// outside the first run, a bad argument) does raise.

import Foundation
import Common

// 128 + SIGINT, what a shell reports for a ^C.
private let interruptedCode: Int32 = 130
private let maxActionDepth = 16
private let logLevels = ["debug", "info", "warn", "error"]
private let debugEnv = "GCT_LUA_DEBUG"
private let exitUnreachable = CLIExit.unreachable.rawValue

// Splits "pane.open" into nested tables on the gct table.
private let nestOps = """
local gct, flat = ...
for path, fn in pairs(flat) do
  local t, parts = gct, {}
  for p in path:gmatch("[^.]+") do parts[#parts + 1] = p end
  for i = 1, #parts - 1 do
    t[parts[i]] = t[parts[i]] or {}
    t = t[parts[i]]
  end
  t[parts[#parts]] = fn
end
"""

// Builders only: they make tables and call nothing. gct.layout.open realizes one.
private let layoutKit = """
gct.layout = gct.layout or {}
function gct.layout.block(spec) return { kind = "block", block = spec or {} } end
function gct.layout.horizontal(ratio, a, b) return { kind = "horizontal", ratio = ratio, first = a, second = b } end
function gct.layout.vertical(ratio, a, b) return { kind = "vertical", ratio = ratio, first = a, second = b } end
"""

// Rex's rex.server(label): the calls of gct, aimed at one peer. Nothing is
// filled in from the calling pane: every pane call names its pane, and a pane
// that runs somewhere else is refused.
private let serverKit = """
function gct.server(label)
  local known = false
  for _, name in ipairs(gct.servers()) do
    if name == label then known = true end
  end
  if not known then error("no such server " .. tostring(label), 2) end

  local function aimed(args)
    local c = {}
    for k, v in pairs(args or {}) do c[k] = v end
    c.host = label
    return c
  end

  local function mine(args)
    local id = args and (args.pane or args.pane_id or args.block_id)
    if not id then return nil, "pane is required on a server" end
    local info, err = gct.pane.inspect{ pane = id }
    if not info then return nil, err end
    if info.host ~= label then return nil, "pane " .. tostring(id) .. " is not on " .. label end
    return true
  end

  local function here(list)
    local out = {}
    for _, p in ipairs(list or {}) do
      if p.host == label then out[#out + 1] = p end
    end
    return out
  end

  local s = { label = label, pane = {}, layout = {}, block = {}, call = gct.call }

  s.pane.open = function(args) return gct.pane.open(aimed(args)) end
  s.layout.open = function(args) return gct.layout.open(aimed(args)) end
  s.pane.list = function() return { panes = here(gct.pane.list().panes) } end
  s.view = function()
    local v, err = gct.view()
    if not v then return nil, err end
    v.panes = here(v.panes)
    return v
  end

  for name, fn in pairs(gct.pane) do
    if not s.pane[name] then
      s.pane[name] = function(args)
        local ok, err = mine(args)
        if not ok then return nil, err end
        return fn(args)
      end
    end
  end

  s.block.call = function(creator, method, args)
    local ok, err = mine(args)
    if not ok then return nil, err end
    return gct.block.call(creator, method, args)
  end

  return s
end
"""

// Rex's rex.bind family. The native table does the work; this only tells it
// where the call came from, which bindings() reports as `source`.
private let keyKit = """
local native = __gct_keys
__gct_keys = nil

local function where()
  local info = debug.getinfo(3, "Sl")
  return info and (info.short_src .. ":" .. info.currentline) or "?"
end

function gct.bind(key, target, args) native.bind(key, target, args, where()) end
function gct.unbind(what, target) return native.unbind(what, target, where()) end
function gct.mode(name, opts) native.mode(name, opts, where()) end
gct.bindings = native.bindings
gct.modes = native.modes
"""

// What a script does about an error in a handler or timer.
enum OnError {
    case carryOn, exit
}

// How a returned value prints.
enum Output {
    case compact, indented
}

private enum TimerKind {
    case once, repeating
}

private let validName = try? NSRegularExpression(pattern: "^[a-z0-9_]+$")

final class ScriptRuntime {
    private let vm: LuaVM
    private let loop: ScriptLoop
    private let ops: ScriptOps
    private let exec: ScriptExec
    private let onError: OnError

    // In registration order: the order handlers run in.
    private var handlers = [(name: String, fn: LuaFunc)]()
    private var actions = [String: LuaFunc]()
    // gct.on is only legal while the script first runs.
    private var armed = true
    private var actionDepth = 0
    private var panes = [PaneID?]()
    private var timerMeta: Int32 = 0
    private var execMeta: Int32 = 0
    private lazy var keys = ScriptKeys(publish: { [unowned self] wire in
        // Best effort: no canvas, or no daemon, is not the script's problem.
        try? self.loop.act { try self.session.send(.canvasCommand, CanvasCommand(verb: .keymap, keymap: wire)) }
    }, same: { [unowned self] in self.vm.same($0, $1) })

    // Shares the keys' token: the canvas names a script by it either way.
    private lazy var palette = ScriptPalette(token: keys.token) { [unowned self] wire in
        try? self.loop.act { try self.session.send(.canvasCommand, CanvasCommand(verb: .palette, palette: wire)) }
    }

    private var session: ScriptSession { loop.session }
    private var pane: PaneID? { panes.last.flatMap { $0 } ?? session.home }

    init?(loop: ScriptLoop, onError: OnError) {
        let modules = PeerConfig.dir()
        guard let vm = LuaVM(modulesDir: modules) else { return nil }

        self.vm = vm
        self.loop = loop
        self.onError = onError
        ops = ScriptOps(loop: loop)
        exec = ScriptExec(loop: loop)
        ops.contextPane = { [unowned self] in self.pane }
        loop.onEvent = { [unowned self] in self.dispatch($0) }
        loop.onInterrupt = { [unowned self] in self.terminate(interruptedCode) }
    }

    // MARK: Running

    // The script's exit status.
    func run(source: String, name: String, args: [String: Any], output: Output, limit: Date?) -> Int32 {
        // Line by line even into a pipe: a script that streams events must
        // not sit on them until its buffer fills.
        setvbuf(stdout, nil, _IOLBF, 0)
        loop.start()
        defer { exec.killAll() }

        do {
            try install(args: args)
            try vm.load(source, name: name)
            try vm.call(nargs: 0, nresults: 1)
            try show(output)
        } catch {
            fail((error as? ScriptError)?.message ?? "\(error)")
            return CLIExit.failed.rawValue
        }

        armed = false
        palette.flush()
        guard !handlers.isEmpty || loop.timerCount > 0 || keys.hasBindings || palette.hasEntries else { return 0 }

        guard loop.pump(until: limit, dispatch: .allow, done: { false }) == .hangup else { return 0 }

        fail("daemon went away")
        return exitUnreachable
    }

    // gct.stop, ^C, --fail-fast: leave now. Not an unwind: a pcall in the
    // script can't turn it into a carry-on.
    private func terminate(_ code: Int32) -> Never {
        exec.killAll()
        fflush(stdout)
        exit(code)
    }

    // The chunk's return value, as JSON; nothing when it returned nothing.
    private func show(_ output: Output) throws {
        defer { vm.pop() }

        guard let v = try vm.value(at: -1) else { return }

        print(try ScriptJSON.encode(v, style: output == .indented ? .indented : .compact))
        fflush(stdout)
    }

    private func fail(_ message: String) {
        FileHandle.standardError.write(Data("gctd: \(message)\n".utf8))
    }

    // MARK: Callbacks

    // Run script code the loop handed us. Errors are reported and the script
    // carries on, unless --fail-fast says otherwise.
    private func callback(_ fn: LuaFunc, _ args: [Any?], pane inPane: PaneID?, what: String) {
        panes.append(inPane ?? pane)
        defer { panes.removeLast() }

        do {
            try vm.call(fn, args)
        } catch let e as ScriptError {
            fail("\(what): \(e.message)")
            if onError == .exit { terminate(CLIExit.failed.rawValue) }
        } catch {
            fail("\(what): \(error)")
        }
    }

    // MARK: Events

    private func matches(_ registered: String, _ e: ScriptEvent) -> Bool {
        let anyTerminal = registered == Evt.anyTerminal || registered == Evt.blockEvent
        return registered == e.name || (anyTerminal && e.name.hasPrefix(Evt.terminalPrefix))
    }

    // Rex's shape: fields flat on ev, and again under ev.payload.
    private func evTable(_ e: ScriptEvent) -> [String: Any] {
        var t = e.fields
        t["payload"] = e.fields
        t["type"] = e.name
        t["name"] = e.name.hasPrefix(Evt.terminalPrefix) ? String(e.name.dropFirst(Evt.terminalPrefix.count)) : e.name
        if let p = e.pane { t["pane_id"] = p.description }
        return t
    }

    private func ctxTable(_ pane: PaneID?, origin: String) -> [String: Any] {
        var t: [String: Any] = ["origin": origin]
        if let p = pane ?? self.pane { t["pane_id"] = p.description }
        return t
    }

    private func dispatch(_ e: ScriptEvent) {
        guard !fromCanvas(e) else { return }

        let ev = evTable(e)
        let ctx = ctxTable(e.pane, origin: "event")

        for h in handlers where matches(h.name, e) {
            callback(h.fn, [ctx, ev], pane: e.pane, what: "handler for \(h.name)")
        }
    }

    // True when the event passes a table (fields equal) or function filter.
    private func passes(_ filterAt: Int32?, _ e: ScriptEvent) -> Bool {
        guard let at = filterAt else { return true }

        if vm.isTable(at) {
            guard let want = try? vm.value(at: at) as? [String: Any] else { return false }

            let have = evTable(e)
            return want.allSatisfy { same(have[$0.key], $0.value) }
        }

        vm.pushCopy(of: at)
        vm.push(evTable(e))
        vm.push(ctxTable(e.pane, origin: "event"))
        guard (try? vm.call(nargs: 2, nresults: 1)) != nil else { return false }

        defer { vm.pop() }
        return vm.isTruthy(at: -1)
    }

    private func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case let (x as String, y as String): return x == y
        case let (x as Bool, y as Bool): return x == y
        case let (x as Int, y as Int): return x == y
        case let (x as Double, y as Double): return x == y
        case let (x as Int, y as Double): return Double(x) == y
        case let (x as Double, y as Int): return x == Double(y)
        default: return false
        }
    }

    // MARK: Install

    private func def(_ name: String, _ b: @escaping LuaBinding) {
        vm.pushFunction(b)
        vm.setField(name)
    }

    private func install(args: [String: Any]) throws {
        vm.newTable()
        installOps()
        installRuntime()
        installTimers()
        installExec()
        installJSON()
        installActions()
        installKeys()

        vm.push(args)
        vm.setField("args")
        vm.push(session.home?.description)
        vm.setField("pane_id")
        vm.setGlobal("gct")

        // After the global exists: the kit adds to it.
        try vm.run(layoutKit, name: "=gct.layout")
        try vm.run(serverKit, name: "=gct.server")
        try vm.run(keyKit, name: "=gct.bind")
    }

    private func installOps() {
        // Flat "pane.open" names first, then nestOps folds them into gct.
        // Stack: gct, chunk, gct, flat -> call -> gct.
        try? vm.load(nestOps, name: "=gct")
        vm.pushCopy(of: -2)
        vm.newTable()

        for (path, op) in ops.table {
            vm.pushFunction { [unowned self] vm in
                guard let dict = try self.arguments(vm, path) else { throw ScriptError("\(path) takes a table") }

                do {
                    vm.push(try op(ScriptArgs(raw: dict)) ?? ([:] as [String: Any]))
                    return 1
                } catch let e as ScriptError {
                    vm.push(nil)
                    vm.push(e.message)
                    return 2
                }
            }
            vm.setField(path)
        }

        try? vm.call(nargs: 2)
    }

    // What a call passed: one table, or for the positional ops (gct.call(method,
    // args)) a leading string and an optional table.
    private func arguments(_ vm: LuaVM, _ path: String) throws -> [String: Any]? {
        guard let keys = ScriptOps.positional[path], let first = try vm.value(at: 1) as? String else {
            return try table(vm, 1)
        }

        var dict: [String: Any] = [keys[0]: first]
        var next: Int32 = 2
        for key in keys.dropFirst() {
            guard let word = try vm.value(at: next) as? String else { throw ScriptError("\(path) takes \(keys.joined(separator: ", "))") }

            dict[key] = word
            next += 1
        }

        if let extra = try table(vm, next), !extra.isEmpty { dict["args"] = extra }
        return dict
    }

    // The table at i (nil or absent is an empty one); nil when it's anything else.
    private func table(_ vm: LuaVM, _ i: Int32) throws -> [String: Any]? {
        if vm.isNil(i) { return [:] }

        return try vm.value(at: i) as? [String: Any]
    }

    private func installRuntime() {
        def("on") { [unowned self] vm in
            guard self.armed else { throw ScriptError("gct.on only works while the script first runs") }
            guard let name = try vm.value(at: 1) as? String, vm.isFunction(2) else {
                throw ScriptError("gct.on(event, fn)")
            }

            guard let fn = try vm.value(at: 2, callables: .hold) as? LuaFunc else { return 0 }

            self.handlers.append((name, fn))
            return 0
        }

        def("wait") { [unowned self] vm in try self.wait(vm) }

        // Rex declares peers in its config file; GCT's live in config.toml.
        def("host") { [unowned self] vm in
            guard self.armed else { throw ScriptError("gct.host declares hosts in a config file; a running script can't add one") }

            FileHandle.standardError.write(Data("[warn] gct.host ignored: hosts are declared in config.toml\n".utf8))
            return 0
        }

        def("sleep") { [unowned self] vm in
            guard let s = self.seconds(vm, 1), s >= 0 else { throw ScriptError("gct.sleep(seconds)") }

            self.loop.pump(until: Date().addingTimeInterval(s), dispatch: .allow) { false }
            return 0
        }

        def("stop") { [unowned self] vm in
            self.terminate(self.seconds(vm, 1).map { Int32($0) } ?? 0)
        }

        def("log") { vm in
            var level = "info"
            var at: Int32 = 1
            if vm.top >= 2, let l = try vm.value(at: 1) as? String, logLevels.contains(l) {
                level = l
                at = 2
            }

            let message = vm.describe(at: at)
            guard level != "debug" || ProcessInfo.processInfo.environment[debugEnv] != nil else { return 0 }

            FileHandle.standardError.write(Data("[\(level)] \(message)\n".utf8))
            return 0
        }
    }

    private func seconds(_ vm: LuaVM, _ i: Int32) -> Double? {
        switch try? vm.value(at: i) {
        case let d as Double where d.isFinite: return d
        case let n as Int: return Double(n)
        default: return nil
        }
    }

    // gct.wait(event[, filter][, timeout]) -> ev, ctx | nil, "timeout"
    private func wait(_ vm: LuaVM) throws -> Int32 {
        guard let name = try vm.value(at: 1) as? String else { throw ScriptError("gct.wait(event[, filter][, timeout])") }

        let filterAt: Int32? = vm.isTable(2) || vm.isFunction(2) ? 2 : nil
        let timeout = seconds(vm, 3) ?? (filterAt == nil ? seconds(vm, 2) : nil)
        let limit = timeout.map { Date().addingTimeInterval($0) }

        var hit: ScriptEvent?
        let end = loop.pump(until: limit, dispatch: .allow) {
            hit = self.loop.takeEvent { self.matches(name, $0) && self.passes(filterAt, $0) }
            return hit != nil
        }

        guard end == .done, let e = hit else {
            vm.push(nil)
            vm.push(end == .hangup ? "daemon went away" : "timeout")
            return 2
        }

        vm.push(evTable(e))
        vm.push(ctxTable(e.pane, origin: "event"))
        return 2
    }

    // MARK: Timers

    private func installTimers() {
        def("after") { [unowned self] vm in try self.timer(vm, kind: .once) }
        def("every") { [unowned self] vm in try self.timer(vm, kind: .repeating) }

        // Methods live on one metatable; a timer is {id=N} wearing it.
        vm.newTable()
        vm.newTable()
        def("cancel") { [unowned self] vm in
            if let id = vm.intField("id", at: 1) { self.loop.cancel(id) }
            return 0
        }
        def("active") { [unowned self] vm in
            vm.push(vm.intField("id", at: 1).map { self.loop.isActive($0) } ?? false)
            return 1
        }
        vm.setField("__index")
        vm.pushCopy(of: -1)
        timerMeta = vm.ref()
        vm.pop()
    }

    private func timer(_ vm: LuaVM, kind: TimerKind) throws -> Int32 {
        guard let s = seconds(vm, 1), s >= 0, !(kind == .repeating && s == 0), vm.isFunction(2) else {
            throw ScriptError(kind == .repeating ? "gct.every(seconds, fn) needs seconds above 0" : "gct.after(seconds, fn)")
        }

        guard let fn = try vm.value(at: 2, callables: .hold) as? LuaFunc else { return 0 }

        // Timers made inside a handler keep acting for that handler's pane.
        let owner = pane
        let t = loop.addTimer(after: s, every: kind == .repeating ? s : nil) { [unowned self] in
            self.callback(fn, [self.ctxTable(owner, origin: "timer")], pane: owner, what: "timer")
        }
        guard let t else {
            fail("too many timers (max \(ScriptLoop.maxTimers))")
            terminate(CLIExit.failed.rawValue)
        }

        handle(["id": t.id], meta: timerMeta)
        return 1
    }

    private func handle(_ fields: [String: Any], meta: Int32) {
        vm.push(fields)
        vm.pushRef(meta)
        vm.setMetatable(at: -2)
    }

    // MARK: Exec

    private func installExec() {
        // gct.exec is a table you can call: gct.exec(argv, opts), gct.exec.start(...)
        vm.newTable()
        def("start") { [unowned self] vm in try self.startExec(vm, argv: 1) }

        vm.newTable()
        def("__call") { [unowned self] vm in
            let (spec, _, _) = try self.execSpec(vm, argv: 2)

            do {
                vm.push(try self.exec.run(spec))
                return 1
            } catch let e as ScriptError {
                    vm.push(nil)
                vm.push(e.message)
                return 2
            }
        }
        vm.setMetatable(at: -2)
        vm.setField("exec")

        vm.newTable()
        vm.newTable()
        installHandleMethods()
        vm.setField("__index")
        vm.pushCopy(of: -1)
        execMeta = vm.ref()
        vm.pop()
    }

    private func execSpec(_ vm: LuaVM, argv: Int32) throws -> (ExecSpec, LuaFunc?, LuaFunc?) {
        let opts = vm.isNil(argv + 1) ? [:] : try vm.value(at: argv + 1, callables: .hold)
        guard let dict = opts as? [String: Any] else { throw ScriptError("exec options must be a table") }

        return try ExecSpec.parse(argv: try vm.value(at: argv), opts: dict)
    }

    private func startExec(_ vm: LuaVM, argv: Int32) throws -> Int32 {
        let (spec, onOut, onErr) = try execSpec(vm, argv: argv)
        let owner = pane

        do {
            let job = try exec.start(spec, onOut: onOut, onErr: onErr) { [unowned self] fn, data in
                self.callback(fn, [String(decoding: data, as: UTF8.self)], pane: owner, what: "exec output")
            }
            handle(["id": job.id, "pid": Int(job.pid)], meta: execMeta)
            return 1
        } catch let e as ScriptError {
            vm.push(nil)
            vm.push(e.message)
            return 2
        }
    }

    private func installHandleMethods() {
        func job(_ s: ScriptRuntime, _ vm: LuaVM) throws -> ExecJob {
            guard let id = vm.intField("id", at: 1), let j = s.exec.job(id) else { throw ScriptError("not a command handle") }

            return j
        }

        def("wait") { [unowned self] vm in
            let j = try job(self, vm)
            let limit = self.seconds(vm, 2).map { Date().addingTimeInterval($0) }
            let end = self.loop.pump(until: limit, dispatch: .allow) { j.finished }
            self.loop.flush()

            guard end == .done else {
                vm.push(nil)
                vm.push(end == .hangup ? "daemon went away" : "timeout")
                return 2
            }

            vm.push(j.result())
            return 1
        }

        def("write") { [unowned self] vm in
            let j = try job(self, vm)
            guard let data = try vm.value(at: 2) as? String else { throw ScriptError("h:write(text)") }

            do {
                try j.write(Data(data.utf8))
                vm.push(true)
                return 1
            } catch {
                vm.push(nil)
                vm.push("\(error)")
                return 2
            }
        }

        def("close_stdin") { [unowned self] vm in
            try job(self, vm).closeStdin()
            return 0
        }

        def("kill") { [unowned self] vm in
            try job(self, vm).signal(try ExecJob.parseSignal(try vm.value(at: 2)))
            return 0
        }

        def("running") { [unowned self] vm in
            vm.push(try job(self, vm).running)
            return 1
        }
    }

    // MARK: JSON

    private func installJSON() {
        vm.newTable()
        def("encode") { vm in
            let indent = (try vm.value(at: 2) as? [String: Any])?["indent"] as? Bool ?? false

            do {
                vm.push(try ScriptJSON.encode(try vm.value(at: 1), style: indent ? .indented : .compact))
                return 1
            } catch let e as ScriptError {
                vm.push(nil)
                vm.push(e.message)
                return 2
            }
        }
        def("decode") { vm in
            guard let text = try vm.value(at: 1) as? String else { throw ScriptError("gct.json.decode(text)") }

            do {
                vm.push(try ScriptJSON.decode(text))
                return 1
            } catch let e as ScriptError {
                vm.push(nil)
                vm.push(e.message)
                return 2
            }
        }
        vm.setField("json")
    }

    // MARK: Actions

    // gct.action{name=, run=} defines one; gct.invoke(name, args) runs it.
    private func installActions() {
        def("action") { [unowned self] vm in
            guard let spec = try vm.value(at: 1, callables: .hold) as? [String: Any],
                  let name = spec["name"] as? String, let run = spec["run"] as? LuaFunc else {
                throw ScriptError("gct.action{name=, run=}")
            }
            guard validName?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else {
                throw ScriptError("action name is lowercase letters, digits and underscores")
            }

            guard self.palette.count < ScriptPalette.maxEntries else {
                throw ScriptError("at most \(ScriptPalette.maxEntries) palette actions")
            }

            self.actions[name] = run
            self.palette.set(name, ScriptPalette.entry(name: name, spec: spec))
            return 0
        }

        def("invoke") { [unowned self] vm in
            guard let name = try vm.value(at: 1) as? String else { throw ScriptError("gct.invoke(name[, args])") }
            guard let fn = self.actions[name] else {
                vm.push(nil)
                vm.push("no such action \(name)")
                return 2
            }
            guard self.actionDepth < maxActionDepth else {
                vm.push(nil)
                vm.push("actions nest too deep")
                return 2
            }

            self.actionDepth += 1
            defer { self.actionDepth -= 1 }

            vm.push(fn)
            vm.push(self.ctxTable(nil, origin: "action"))
            vm.pushCopy(of: 2)
            do {
                try vm.call(nargs: 2, nresults: 1)
                return 1
            } catch let e as ScriptError {
                    vm.push(nil)
                vm.push(e.message)
                return 2
            }
        }
    }
}

// MARK: - Keys

// Same file, so the extension reaches the runtime's private state.
extension ScriptRuntime {
    // Events from the canvas that only the runtime wants: a bound key was hit or
    // a palette entry picked, or a canvas came up and needs the keymap and the
    // palette again.
    fileprivate func fromCanvas(_ e: ScriptEvent) -> Bool {
        switch e.name {
        case PaneEventName.canvasUp:
            keys.resend()
            palette.resend()
            return true
        case PaneEventName.keyFired:
            fire(e)
            return true
        default:
            return false
        }
    }

    private func fire(_ e: ScriptEvent) {
        guard let hit = keys.firing(e.fields) else { return }

        let focused = (e.fields["pane_id"] as? String).flatMap { PaneID(string: $0) }
        let ctx = ctxTable(focused, origin: e.fields["origin"] as? String ?? "key")
        let what = "key \(hit.label)"

        switch hit.run {
        case .function(let fn):
            let kept = answer(fn, [ctx, hit.fields], pane: focused, what: what)
            if let req = hit.req { reply(req, handled: kept) }
        case .action(let name, let args):
            guard let fn = actions[name] else {
                fail("\(what): no such action \(name)")
                return
            }

            callback(fn, [ctx, args ?? [:]], pane: focused, what: what)
        }
    }

    // The function's verdict on its key: true keeps it, anything else lets it
    // through. A function that raised still got its key: it was meant for it.
    private func answer(_ fn: LuaFunc, _ args: [Any?], pane inPane: PaneID?, what: String) -> Bool {
        panes.append(inPane ?? pane)
        defer { panes.removeLast() }

        do {
            return (try vm.invoke(fn, args) as? Bool) == true
        } catch let e as ScriptError {
            fail("\(what): \(e.message)")
            if onError == .exit { terminate(CLIExit.failed.rawValue) }
        } catch {
            fail("\(what): \(error)")
        }

        return true
    }

    private func reply(_ req: String, handled: Bool) {
        let r = KeyReply(token: keys.token, req: req, handled: handled)
        try? loop.act { try self.session.send(.canvasCommand, CanvasCommand(verb: .reply, reply: r)) }
    }

    fileprivate func installKeys() {
        vm.newTable()

        def("bind") { [unowned self] vm in
            guard let key = try vm.value(at: 1) as? String else {
                throw ScriptError("gct.bind: expected a string key, got \(vm.describe(at: 1))")
            }

            let source = try vm.value(at: 4) as? String ?? "?"
            if vm.isFunction(2) {
                guard let fn = try vm.value(at: 2, callables: .hold) as? LuaFunc else { return 0 }

                try self.keys.bind(key, .function(fn), source: source)
                return 0
            }

            guard let action = try vm.value(at: 2) as? String else {
                throw ScriptError("gct.bind(key, action[, args]) or gct.bind(key, fn)")
            }

            try self.keys.bind(key, .action(action, args: try vm.value(at: 3) as? [String: Any]), source: source)
            return 0
        }

        def("unbind") { [unowned self] vm in
            let source = try vm.value(at: 3) as? String ?? "?"

            if vm.isTable(1) {
                return try self.unbindTable(vm, source: source)
            }
            guard let key = try vm.value(at: 1) as? String else { throw ScriptError("gct.unbind(key[, target])") }

            var only: KeyRun?
            if vm.isFunction(2) {
                only = (try vm.value(at: 2, callables: .hold) as? LuaFunc).map { .function($0) }
            } else if let name = try vm.value(at: 2) as? String {
                only = .action(name, args: nil)
            }

            vm.push(try self.keys.unbind(key, only: only, source: source))
            return 1
        }

        def("mode") { [unowned self] vm in
            guard let name = try vm.value(at: 1) as? String else { throw ScriptError("gct.mode(name[, {exclusive = bool}])") }

            let opts = try vm.value(at: 2) as? [String: Any] ?? [:]
            for k in opts.keys where k != "exclusive" {
                throw ScriptError("gct.mode: exclusive is the only option, not \(k)")
            }
            guard opts["exclusive"] == nil || opts["exclusive"] is Bool else { throw ScriptError("gct.mode: exclusive is true or false") }

            let source = try vm.value(at: 3) as? String ?? "?"
            try self.keys.mode(name, exclusive: opts["exclusive"] as? Bool ?? false, source: source)
            return 0
        }

        def("bindings") { [unowned self] vm in
            let f = try vm.value(at: 1) as? [String: Any] ?? [:]
            vm.push(self.keys.bindings(key: f["key"] as? String, mode: f["mode"] as? String, action: f["action"] as? String))
            return 1
        }

        def("modes") { [unowned self] vm in
            vm.push(self.keys.modeList())
            return 1
        }

        vm.setGlobal("__gct_keys")
    }

    // unbind{mode = name}, or unbind(a table bindings() gave back).
    private func unbindTable(_ vm: LuaVM, source: String) throws -> Int32 {
        guard let t = try vm.value(at: 1, callables: .hold) as? [String: Any] else { throw ScriptError("gct.unbind(key[, target])") }

        if let mode = t["mode"] as? String, t["key"] == nil {
            keys.unbind(mode: mode)
            vm.push(0)
            return 1
        }

        guard let key = t["key"] as? String else { throw ScriptError("gct.unbind: a binding has a key") }

        let full = (t["mode"] as? String).map { "\($0)/\(key)" } ?? key
        var run: KeyRun?
        if let fn = t["fn"] as? LuaFunc {
            run = .function(fn)
        } else if let name = t["action"] as? String {
            run = .action(name, args: nil)
        }
        guard let run else { throw ScriptError("gct.unbind: a binding has an action or a fn") }

        vm.push(try keys.unbind(binding: full, run: run))
        return 1
    }
}
