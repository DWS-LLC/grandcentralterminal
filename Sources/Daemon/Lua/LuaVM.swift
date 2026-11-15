// The Lua C API behind a small Swift face: the only file that imports CLua.
// Everything above it speaks Swift values (Any: nil, Bool, Int, Double,
// String, Data, [Any], [String: Any]) and never sees a stack index.
//
//   script ──► Lua VM ──► trampoline ──► LuaBinding (Swift closure)
//                              ▲                │ throws ScriptError
//                              └── lua_error ◄──┘  (raised after Swift unwinds)
//
// lua_error longjmps. Swift frames skipped by a longjmp leak their locals, so
// a binding never raises: it throws, the trampoline's helper returns, and only
// then is lua_error called with nothing of ours left on the C stack.

import Foundation
import CLua

struct ScriptError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// Reads its arguments off the VM, pushes its results, returns how many.
typealias LuaBinding = (LuaVM) throws -> Int32

// What value(at:) does with a Lua function: refuse it, or hold on to it.
enum Callables {
    case reject, hold
}

// -LUAI_MAXSTACK - 1000: macro arithmetic Swift can't import.
private let registryIndex: Int32 = -1_001_000
private let maxDepth = 32
private let searchPathTail = "/lua/?.lua"

private let locked = """
io.popen = function() error("io.popen is disabled; use gct.exec", 2) end
os.execute = function() error("os.execute is disabled; use gct.exec", 2) end
package.cpath = ""
"""

private let luaTrampoline: lua_CFunction = { state in
    guard let state else { return 0 }

    let n = LuaVM.dispatch(state)
    if n < 0 {
        return lua_error(state)
    }

    return n
}

// A Lua function Swift holds on to (a registry ref). Release it on the loop
// thread, the only one that touches the VM.
final class LuaFunc {
    fileprivate let ref: Int32
    private unowned let vm: LuaVM

    fileprivate init(ref: Int32, vm: LuaVM) {
        self.ref = ref
        self.vm = vm
    }

    deinit {
        vm.unref(ref)
    }
}

final class LuaVM {
    // One VM per process; the trampoline finds it through here.
    nonisolated(unsafe) private static var shared: LuaVM?
    nonisolated(unsafe) private static var bindings = [LuaBinding]()

    private let state: OpaquePointer

    init?(modulesDir: String) {
        guard let s = luaL_newstate() else { return nil }

        state = s
        luaL_openlibs(s)
        LuaVM.shared = self

        // Lua modules next to config.toml; no C modules (no dlopen when static).
        do {
            try run(locked, name: "=lock")
        } catch {
            return nil
        }

        lua_getglobal(s, "package")
        push(modulesDir + searchPathTail + ";")
        lua_getfield(s, -2, "path")
        lua_concat(s, 2)
        lua_setfield(s, -2, "path")
        lua_settop(s, -2)
    }

    // MARK: Trampoline

    fileprivate static func dispatch(_ s: OpaquePointer) -> Int32 {
        let slot = Int(lua_tointegerx(s, registryIndex - 1, nil))
        guard let vm = shared, bindings.indices.contains(slot) else { return 0 }

        do {
            return try bindings[slot](vm)
        } catch let e as ScriptError {
            vm.push(e.message)
        } catch {
            vm.push("\(error)")
        }

        return -1
    }

    // MARK: Stack

    var top: Int32 { lua_gettop(state) }

    func pop(_ n: Int32 = 1) {
        lua_settop(state, -n - 1)
    }

    func isNil(_ i: Int32) -> Bool {
        let t = lua_type(state, i)
        return t == LUA_TNIL || t == LUA_TNONE
    }

    func isFunction(_ i: Int32) -> Bool {
        lua_type(state, i) == LUA_TFUNCTION
    }

    func isTable(_ i: Int32) -> Bool {
        lua_type(state, i) == LUA_TTABLE
    }

    // MARK: Values

    func push(_ v: Any?) {
        switch v {
        case nil, is NSNull:
            lua_pushnil(state)
        case let b as Bool:
            lua_pushboolean(state, b ? 1 : 0)
        case let n as any BinaryInteger:
            lua_pushinteger(state, Int64(n))
        case let d as Double:
            lua_pushnumber(state, d)
        case let s as String:
            pushBytes(Array(s.utf8))
        case let d as Data:
            pushBytes(Array(d))
        case let f as LuaFunc:
            pushRef(f.ref)
        case let a as [Any]:
            lua_createtable(state, Int32(a.count), 0)
            for (i, item) in a.enumerated() {
                push(item)
                lua_rawseti(state, -2, Int64(i + 1))
            }
        case let m as [String: Any]:
            lua_createtable(state, 0, Int32(m.count))
            for (k, item) in m {
                push(item)
                lua_setfield(state, -2, k)
            }
        default:
            push(String(describing: v))
        }
    }

    private func pushBytes(_ b: [UInt8]) {
        b.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else {
                lua_pushlstring(state, "", 0)
                return
            }

            lua_pushlstring(state, UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self), buf.count)
        }
    }

    // The value at i as Swift. Functions, threads and userdata can't cross.
    func value(at idx: Int32, depth: Int = 0, callables: Callables = .reject) throws -> Any? {
        let i = lua_absindex(state, idx)

        switch lua_type(state, i) {
        case LUA_TNIL, LUA_TNONE:
            return nil
        case LUA_TBOOLEAN:
            return lua_toboolean(state, i) != 0
        case LUA_TNUMBER:
            if lua_isinteger(state, i) != 0 {
                return Int(lua_tointegerx(state, i, nil))
            }
            return lua_tonumberx(state, i, nil)
        case LUA_TSTRING:
            return bytes(at: i)
        case LUA_TTABLE:
            guard depth < maxDepth else { throw ScriptError("table nests too deep or contains itself") }
            return try table(at: i, depth: depth, callables: callables)
        case LUA_TFUNCTION where callables == .hold:
            lua_pushvalue(state, i)
            return LuaFunc(ref: ref(), vm: self)
        default:
            let name = String(cString: lua_typename(state, lua_type(state, i)))
            throw ScriptError("a \(name) can't be passed here")
        }
    }

    // Valid UTF-8 comes back as String, anything else stays raw bytes.
    private func bytes(at i: Int32) -> Any {
        var len = 0
        guard let p = lua_tolstring(state, i, &len) else { return "" }

        let data = Data(bytes: p, count: len)
        return String(data: data, encoding: .utf8) ?? data
    }

    // Keys 1..n and nothing else make an array; anything else a dictionary.
    private func table(at i: Int32, depth: Int, callables: Callables) throws -> Any {
        var ints = [Int: Any]()
        var named = [String: Any]()

        lua_pushnil(state)
        while lua_next(state, i) != 0 {
            defer { pop() }

            let item = try value(at: -1, depth: depth + 1, callables: callables) as Any

            if lua_isinteger(state, -2) != 0 {
                ints[Int(lua_tointegerx(state, -2, nil))] = item
                continue
            }

            // A copy: tolstring would convert a numeric key in place and
            // derail lua_next.
            lua_pushvalue(state, -2)
            named[string(at: -1)] = item
            pop()
        }

        let isArray = named.isEmpty && !ints.isEmpty && ints.keys.allSatisfy { (1...ints.count).contains($0) }
        if isArray {
            return (1...ints.count).map { ints[$0] as Any }
        }

        for (k, item) in ints { named[String(k)] = item }
        return named
    }

    func string(at i: Int32) -> String {
        var len = 0
        guard let p = lua_tolstring(state, i, &len) else { return "" }

        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }

    // luaL_tolstring honours __tostring; leaves the string on the stack.
    func describe(at i: Int32) -> String {
        var len = 0
        guard let p = luaL_tolstring(state, i, &len) else { return "?" }

        defer { pop() }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }

    // MARK: Tables and globals

    func newTable() {
        lua_createtable(state, 0, 0)
    }

    // table at -2, value at -1: table[name] = value (pops the value).
    func setField(_ name: String) {
        lua_setfield(state, -2, name)
    }

    // Pushes table[name].
    func getField(_ name: String, at i: Int32) {
        lua_getfield(state, i, name)
    }

    func setGlobal(_ name: String) {
        lua_setglobal(state, name)
    }

    func getGlobal(_ name: String) {
        lua_getglobal(state, name)
    }

    func setMetatable(at i: Int32) {
        lua_setmetatable(state, i)
    }

    // MARK: Functions

    func pushFunction(_ b: @escaping LuaBinding) {
        LuaVM.bindings.append(b)
        lua_pushinteger(state, Int64(LuaVM.bindings.count - 1))
        lua_pushcclosure(state, luaTrampoline, 1)
    }

    // MARK: Registry refs: how Swift holds on to Lua functions.

    func ref() -> Int32 {
        luaL_ref(state, registryIndex)
    }

    func pushRef(_ r: Int32) {
        lua_rawgeti(state, registryIndex, Int64(r))
    }

    func unref(_ r: Int32) {
        luaL_unref(state, registryIndex, r)
    }

    // MARK: Running

    // Function plus nargs arguments on the stack; leaves nresults (or all of
    // them for LUA_MULTRET) and throws the error message otherwise.
    func call(nargs: Int32, nresults: Int32 = 0) throws {
        guard lua_pcallk(state, nargs, nresults, 0, 0, nil) == LUA_OK else {
            let message = describe(at: -1)
            pop()
            throw ScriptError(message)
        }
    }

    // Call a held function; its first result (nil when none) comes back.
    @discardableResult
    func invoke(_ f: LuaFunc, _ args: [Any?]) throws -> Any? {
        pushRef(f.ref)
        for a in args { push(a) }
        try call(nargs: Int32(args.count), nresults: 1)

        defer { pop() }
        return try value(at: -1)
    }

    func push(_ f: LuaFunc) {
        pushRef(f.ref)
    }

    // Two held functions that are the same Lua function (refs differ per hold).
    func same(_ a: LuaFunc, _ b: LuaFunc) -> Bool {
        pushRef(a.ref)
        pushRef(b.ref)
        defer { pop(2) }

        return lua_rawequal(state, -1, -2) != 0
    }

    // Call a held function and drop whatever it returns.
    func call(_ f: LuaFunc, _ args: [Any?]) throws {
        pushRef(f.ref)
        for a in args { push(a) }
        try call(nargs: Int32(args.count))
    }

    // A copy of the value at i, on top.
    func pushCopy(of i: Int32) {
        lua_pushvalue(state, i)
    }

    // table[name] as an integer, for the handles scripts hold. Raw, so a
    // metatable a script put there can't raise through our frames.
    func intField(_ name: String, at i: Int32) -> Int? {
        let table = lua_absindex(state, i)
        push(name)
        lua_rawget(state, table)
        defer { pop() }

        guard lua_isinteger(state, -1) != 0 else { return nil }

        return Int(lua_tointegerx(state, -1, nil))
    }

    func isTruthy(at i: Int32) -> Bool {
        lua_toboolean(state, i) != 0
    }

    func load(_ source: String, name: String) throws {
        let rc = source.utf8CString.withUnsafeBufferPointer {
            luaL_loadbufferx(state, $0.baseAddress, $0.count - 1, name, nil)
        }
        guard rc == LUA_OK else {
            let message = describe(at: -1)
            pop()
            throw ScriptError(message)
        }
    }

    // Compile and run; returns the chunk's first result (popped).
    @discardableResult
    func run(_ source: String, name: String) throws -> Any? {
        let base = top
        try load(source, name: name)
        try call(nargs: 0, nresults: 1)
        defer { pop(top - base) }
        return try value(at: -1)
    }
}
