// Install, restore, update and remove plugins. The CLI calls this; this calls
// PluginGit for the mechanics and PluginStore for the layout.
//
//   install owner/repo ──► clone aside ──► check init.lua ──► rename into plugins/
//                                                              └─► pin commit in plugins.lock
//
// A plugin is cloned beside its final folder and renamed in, so autoload
// (which rescans every couple of seconds) never starts a half-written one.

import Foundation

enum PluginUpdate {
    case moved(String, from: String, to: String)
    case current(String, String)
    case failed(String, String)
}

// `owner/repo` is GitHub; anything that looks like a URL or a path is taken as is.
private struct PluginSource {
    let url: String
    let name: String

    private static let github = "https://github.com/"
    private static let schemeMark = "://"
    private static let urlPrefixes = ["git@", "/", "./", "../"]
    private static let gitSuffix = ".git"

    init?(_ spec: String) {
        let isURL = spec.contains(Self.schemeMark) || Self.urlPrefixes.contains { spec.hasPrefix($0) }
        let parts = spec.split(separator: "/", omittingEmptySubsequences: false)
        let isRepo = parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
        guard isURL || isRepo else { return nil }

        url = isURL ? spec : Self.github + spec + Self.gitSuffix

        var last = String(spec.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
        if last.hasSuffix(Self.gitSuffix) {
            last.removeLast(Self.gitSuffix.count)
        }
        name = last
    }
}

enum PluginManager {
    private static let upstreamHead = "origin/HEAD"
    private static let originPrefix = "origin/"

    // MARK: Install

    static func install(_ spec: String, name wanted: String?, ref: String?) throws -> Plugin {
        guard let source = PluginSource(spec) else {
            throw PluginError("\(spec): expected owner/repo or a git URL")
        }

        let name = wanted ?? source.name
        guard PluginStore.valid(name) else {
            throw PluginError("\(name) can't be a plugin name: letters, digits, . _ - and no leading dot (--name picks one)")
        }
        guard !(ref?.hasPrefix("-") ?? false) else {
            throw PluginError("--ref \(ref ?? "") looks like an option")
        }
        guard !PluginStore.hasEntry(name) else {
            throw PluginError("\(name) is already in \(PluginStore.dir()) (gctd plugin update \(name))")
        }

        var lock = try PluginStore.readLock()
        let commit = try place(source.url, as: name, at: ref)
        lock.plugins[name] = PluginPin(source: spec, ref: ref, commit: commit)

        do {
            try PluginStore.writeLock(lock)
        } catch {
            try? FileManager.default.removeItem(atPath: PluginStore.path(of: name))
            throw error
        }

        guard let plugin = PluginStore.find(name) else {
            throw PluginError("\(name) installed but has no \(PluginStore.initFile)")
        }

        return plugin
    }

    // The lockfile's plugins that aren't on disk, back at their pinned commits:
    // a fresh machine with a committed plugins.lock.
    static func restore() throws -> [String] {
        let lock = try PluginStore.readLock()
        var restored = [String]()

        for (name, pin) in lock.plugins.sorted(by: { $0.key < $1.key }) {
            guard !PluginStore.hasEntry(name) else { continue }
            guard let source = PluginSource(pin.source) else {
                throw PluginError("plugins.lock: \(name) has a source I can't read (\(pin.source))")
            }

            _ = try place(source.url, as: name, at: pin.commit)
            restored.append(name)
        }

        return restored
    }

    // Clones aside, checks out `rev`, checks for init.lua, then renames into
    // place. Returns the commit it ended on.
    private static func place(_ url: String, as name: String, at rev: String?) throws -> String {
        let fm = FileManager.default
        let aside = "\(PluginStore.dir())/.\(name).\(getpid()).tmp"

        do {
            try fm.createDirectory(atPath: PluginStore.dir(), withIntermediateDirectories: true)
            try PluginGit.clone(url, to: aside)
            if let rev {
                try PluginGit.checkout(rev, in: aside)
            }
            guard PluginStore.hasInit(at: aside) else {
                throw PluginError("\(url) has no \(PluginStore.initFile) at its top level")
            }

            let commit = try PluginGit.head(in: aside)
            try fm.moveItem(atPath: aside, toPath: PluginStore.path(of: name))
            return commit
        } catch {
            try? fm.removeItem(atPath: aside)
            throw error
        }
    }

    // MARK: Update

    // Fetch, then move each plugin to what its ref names now: the default
    // branch's tip with no ref, a branch's tip, or the same tag or commit.
    // One failing plugin doesn't stop the rest.
    static func update(_ only: String?) throws -> [PluginUpdate] {
        var lock = try PluginStore.readLock()
        if let only, lock.plugins[only] == nil {
            throw PluginError("\(only) wasn't installed by gctd, so there is nothing to update")
        }

        let names = only.map { [$0] } ?? lock.plugins.keys.sorted()
        var out = [PluginUpdate]()

        for name in names {
            guard var pin = lock.plugins[name] else { continue }

            do {
                let now = try advance(name, pin)
                out.append(now == pin.commit ? .current(name, now) : .moved(name, from: pin.commit, to: now))
                pin.commit = now
                lock.plugins[name] = pin
            } catch {
                out.append(.failed(name, (error as? PluginError)?.message ?? "\(error)"))
            }
        }

        try PluginStore.writeLock(lock)
        return out
    }

    private static func advance(_ name: String, _ pin: PluginPin) throws -> String {
        guard PluginStore.hasEntry(name) else {
            throw PluginError("folder is gone; gctd plugin install puts it back")
        }

        let dir = PluginStore.path(of: name)
        try PluginGit.fetch(in: dir)
        try PluginGit.checkout(target(pin.ref, in: dir), in: dir)
        return try PluginGit.head(in: dir)
    }

    // A branch name means its remote tip; a tag or a commit means itself.
    private static func target(_ ref: String?, in dir: String) -> String {
        guard let ref else { return upstreamHead }

        let branch = originPrefix + ref
        return PluginGit.has(branch, in: dir) ? branch : ref
    }

    // MARK: Remove

    // Only what gctd installed: a folder you made yourself is yours to delete.
    static func remove(_ name: String) throws {
        var lock = try PluginStore.readLock()
        guard lock.plugins[name] != nil else {
            let hint = PluginStore.hasEntry(name) ? "it was put there by hand; delete \(PluginStore.path(of: name)) yourself" : "no such plugin"
            throw PluginError("\(name): \(hint)")
        }
        guard PluginStore.valid(name) else {
            throw PluginError("\(name) can't be a plugin name")
        }

        if PluginStore.hasEntry(name) {
            try FileManager.default.removeItem(atPath: PluginStore.path(of: name))
        }

        lock.plugins[name] = nil
        try PluginStore.writeLock(lock)
    }
}
