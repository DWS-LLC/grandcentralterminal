// `gctd plugin`: parse the command line, call PluginManager, print.
//
//   gctd plugin install owner/repo           clone, pin, autoload starts it
//   gctd plugin install                      put back whatever plugins.lock names
//   gctd plugin list [--json]
//   gctd plugin update [name]
//   gctd plugin remove name

import Foundation

private let pluginUsage = "plugin install [owner/repo | url] [--name NAME] [--ref REF] | list [--json] | update [name] | remove <name>"
private let shortCommit = 7
private let dash = "-"
private let byHand = "(local)"
private let versionWidth = 6

private struct PluginRow: Encodable {
    let name: String
    let version: String
    let description: String
    let source: String
    let commit: String
    let managed: Bool
    let enabled: Bool
    let path: String
}

private func pluginRows() -> [PluginRow] {
    PluginStore.installed().map { p in
        PluginRow(name: p.name, version: p.manifest.version, description: p.manifest.description,
                  source: p.pin?.source ?? "", commit: p.pin?.commit ?? "", managed: p.pin != nil,
                  enabled: PluginStore.isEnabled(PluginStore.options(of: p.name)), path: p.path)
    }
}

private func column(_ text: String, _ width: Int) -> String {
    text.padding(toLength: max(text.count, width), withPad: " ", startingAt: 0)
}

private func listPlugins(_ args: [String]) -> Never {
    let all = pluginRows()
    if args.contains("--json") {
        printJSON(["plugins": all])
        exit(CLIExit.ok.rawValue)
    }

    if all.isEmpty {
        print("no plugins in \(PluginStore.dir())")
    }

    let width = all.map(\.name.count).max() ?? 0
    for r in all {
        let at = r.managed ? "\(r.commit.prefix(shortCommit))  \(r.source)" : "\(dash)  \(byHand)"
        let off = r.enabled ? "" : "  (disabled)"
        print("\(column(r.name, width))  \(column(r.version.isEmpty ? dash : r.version, versionWidth))  \(at)\(off)")
    }

    exit(CLIExit.ok.rawValue)
}

private struct InstallOptions {
    var spec: String?
    var name: String?
    var ref: String?
}

private func installOptions(_ args: [String]) -> InstallOptions {
    var o = InstallOptions()
    var it = args.makeIterator()

    while let a = it.next() {
        switch a {
        case "--name":
            guard let v = it.next() else { bad("--name needs a value") }

            o.name = v
        case "--ref":
            guard let v = it.next() else { bad("--ref needs a value") }

            o.ref = v
        case _ where a.hasPrefix("-"):
            bad(pluginUsage)
        default:
            guard o.spec == nil else { bad(pluginUsage) }

            o.spec = a
        }
    }

    return o
}

private func restorePlugins() -> Never {
    do {
        let restored = try PluginManager.restore()
        print(restored.isEmpty ? "nothing to restore" : "restored \(restored.joined(separator: ", "))")
        exit(CLIExit.ok.rawValue)
    } catch let e as PluginError {
        die(e.message)
    } catch {
        die("\(error)")
    }
}

private func installPlugin(_ args: [String]) -> Never {
    let o = installOptions(args)
    guard let spec = o.spec else {
        guard o.name == nil, o.ref == nil else { bad(pluginUsage) }

        restorePlugins()
    }

    do {
        let p = try PluginManager.install(spec, name: o.name, ref: o.ref)
        print("installed \(p.name) at \(p.pin?.commit.prefix(shortCommit) ?? "?"); it starts with the daemon within a few seconds")
        print("a plugin runs with your permissions: read it first (\(p.path))")
        exit(CLIExit.ok.rawValue)
    } catch let e as PluginError {
        die(e.message)
    } catch {
        die("\(error)")
    }
}

private func updatePlugins(_ args: [String]) -> Never {
    guard args.count <= 1 else { bad(pluginUsage) }

    do {
        var failures = 0
        for u in try PluginManager.update(args.first) {
            switch u {
            case let .moved(name, from, to):
                print("\(name)  \(from.prefix(shortCommit)) -> \(to.prefix(shortCommit))")
            case let .current(name, at):
                print("\(name)  up to date (\(at.prefix(shortCommit)))")
            case let .failed(name, why):
                failures += 1
                FileHandle.standardError.write(Data("gctd: \(name): \(why)\n".utf8))
            }
        }

        exit(failures == 0 ? CLIExit.ok.rawValue : CLIExit.failed.rawValue)
    } catch let e as PluginError {
        die(e.message, .notFound)
    } catch {
        die("\(error)")
    }
}

private func removePlugin(_ args: [String]) -> Never {
    guard args.count == 1 else { bad(pluginUsage) }

    do {
        try PluginManager.remove(args[0])
        print("removed \(args[0])")
        exit(CLIExit.ok.rawValue)
    } catch let e as PluginError {
        die(e.message, .notFound)
    } catch {
        die("\(error)")
    }
}

// `plugin ...`: every path exits.
func runPlugin(_ rest: [String]) -> Never {
    guard let sub = rest.first else { bad(pluginUsage) }

    let args = Array(rest.dropFirst())
    switch sub {
    case "install": installPlugin(args)
    case "list": listPlugins(args)
    case "update": updatePlugins(args)
    case "remove": removePlugin(args)
    default: bad(pluginUsage)
    }
}
