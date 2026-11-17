// gctd agent — how a coding agent finds out about GCT.
//
//   gctd agent setup   [--agent NAME]... [--project] [--dry-run] [--force] [--json]
//   gctd agent status  same flags; changes nothing, exits 1 unless all current
//   gctd agent remove  same flags; takes the skill and hooks back out
//   gctd agent show    print the guide the installed skill points at
//   gctd agent context print where the caller is (what the SessionStart hook emits)
//
// Two things get installed per agent:
//
//   skill  a stub SKILL.md that says "run `gctd agent show`" (see AgentGuide)
//   hook   SessionStart context, plus desktop pings on Notification/Stop
//          where the agent has those events (hook merging: AgentHooks)
//
//   agent     skill dir                     hook file
//   claude    ~/.claude/skills/gct          ~/.claude/settings.json
//   codex     ~/.agents/skills/gct          ~/.codex/hooks.json
//   opencode  ~/.agents/skills/gct          —
//   pi        ~/.agents/skills/gct          —
//
// Setup is idempotent: current items are reported `unchanged` and not
// rewritten. A file we can't parse is left alone and reported `failed`.

import Foundation
import Common

// MARK: - Vocabulary

enum Agent: String, CaseIterable {
    case claude
    case codex
    case opencode
    case pi
}

enum AgentScope: String {
    case user
    case project
}

enum RunMode {
    case apply
    case dryRun
}

enum Overwrite {
    case keep
    case replace
}

enum OutputFormat {
    case text
    case json
}

// Which agents a command covers when none are named.
enum Pool {
    case found
    case all
}

// What setup or remove did to an item (or would, in a dry run).
enum AgentAction: String {
    case installed
    case updated
    case replaced
    case removed
    case unchanged
    case skipped
    case failed
}

// What status found.
enum ItemState: String {
    case current
    case outdated
    case missing
    case foreign
    case unreadable
    case unsupported
}

struct AgentOptions {
    var named = [Agent]()
    var scope = AgentScope.user
    var mode = RunMode.apply
    var overwrite = Overwrite.keep
    var format = OutputFormat.text
}

private let agentUsage = "agent setup|status|remove|show|context [--agent NAME]... [--project] [--dry-run] [--force] [--json]"
private let skillName = "gct"
private let skillFile = "SKILL.md"
private let startEvent = "SessionStart"
private let noticeEvents = ["Notification", "Stop"]
// SessionStart can't block: expiry discards the output and the session
// proceeds, so the timeout only bounds a wedged daemon.
private let contextTimeout = 15
private let noticeTimeout = 10
private let codexApproval = "Codex runs the hook once you approve it with /hooks"

// MARK: - Where things live

// $HOME first (agents/sandboxes override it; also makes isolated-HOME
// testing possible), passwd fallback. NSHomeDirectory() ignores $HOME.
func agentHome() -> String {
    envVar("HOME") ?? NSHomeDirectory()
}

private func envVar(_ key: String) -> String? {
    guard let v = ProcessInfo.processInfo.environment[key], !v.isEmpty else { return nil }

    return v
}

private func userConfigDir(_ a: Agent) -> String {
    let home = agentHome()
    switch a {
    case .claude:
        return envVar("CLAUDE_CONFIG_DIR") ?? home + "/.claude"
    case .codex:
        return envVar("CODEX_HOME") ?? home + "/.codex"
    case .opencode:
        return home + "/.config/opencode"
    case .pi:
        return home + "/.pi"
    }
}

// Found = has a config dir, or its program is on PATH.
private func isFound(_ a: Agent) -> Bool {
    if FileManager.default.fileExists(atPath: userConfigDir(a)) {
        return true
    }

    let dirs = (envVar("PATH") ?? "").split(separator: ":")
    return dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(a.rawValue)") }
}

// Nearest ancestor holding .git, else the current directory.
private func projectRoot() -> String {
    let fm = FileManager.default
    let cwd = fm.currentDirectoryPath
    var dir = cwd
    while dir != "/" {
        if fm.fileExists(atPath: dir + "/.git") {
            return dir
        }
        dir = (dir as NSString).deletingLastPathComponent
    }

    return cwd
}

struct AgentTarget {
    let agent: Agent
    let skillDir: String
    let hookFile: String?
    let hookEvents: [String]
    let matcher: String?
}

private func target(_ a: Agent, _ scope: AgentScope) -> AgentTarget {
    let base = scope == .user ? agentHome() : projectRoot()
    let shared = "\(base)/.agents/skills/\(skillName)"

    switch a {
    case .claude:
        let cfg = scope == .user ? userConfigDir(a) : base + "/.claude"
        return AgentTarget(agent: a, skillDir: "\(cfg)/skills/\(skillName)",
                           hookFile: cfg + "/settings.json",
                           hookEvents: [startEvent] + noticeEvents, matcher: "")
    case .codex:
        let cfg = scope == .user ? userConfigDir(a) : base + "/.codex"
        return AgentTarget(agent: a, skillDir: shared, hookFile: cfg + "/hooks.json",
                           hookEvents: [startEvent], matcher: nil)
    case .opencode, .pi:
        return AgentTarget(agent: a, skillDir: shared, hookFile: nil, hookEvents: [], matcher: nil)
    }
}

private func selected(_ o: AgentOptions, from pool: Pool) -> [AgentTarget] {
    var agents = o.named
    if agents.isEmpty {
        agents = Agent.allCases.filter { pool == .all || isFound($0) }
    }

    var seen = Set<Agent>()
    return agents.filter { seen.insert($0).inserted }.map { target($0, o.scope) }
}

// Agents sharing a skill dir (codex, opencode, pi) are one install.
private func bySkillDir(_ ts: [AgentTarget]) -> [(dir: String, agents: String)] {
    var order = [String]()
    var names = [String: [String]]()
    for t in ts {
        if names[t.skillDir] == nil {
            order.append(t.skillDir)
        }
        names[t.skillDir, default: []].append(t.agent.rawValue)
    }

    return order.map { ($0, (names[$0] ?? []).joined(separator: ",")) }
}

// MARK: - Hook commands

// Prefers /usr/local/bin/gctd: no spaces, stable across rebuilds. Falls
// back to the running binary, quoted when its path has spaces.
private func hookBin() -> String {
    let linked = "/usr/local/bin/gctd"
    if FileManager.default.isExecutableFile(atPath: linked) {
        return linked
    }

    var me = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "gctd"
    if !me.hasPrefix("/") {
        me = FileManager.default.currentDirectoryPath + "/" + me
    }

    return me.contains(" ") ? "\"\(me)\"" : me
}

// `|| exit 0`: fail open. An unexecable binary (bad signature, missing
// path) exits nonzero with empty stderr, which the agent would surface as
// a hook error every session.
private func hookSpecs(_ t: AgentTarget) -> [HookSpec] {
    let bin = hookBin()

    return t.hookEvents.map { event in
        if event == startEvent {
            return HookSpec(event: event, command: "\(bin) agent context || exit 0",
                            timeout: contextTimeout, matcher: t.matcher)
        }

        return HookSpec(event: event, command: "\(bin) notify self --hook || exit 0",
                        timeout: noticeTimeout, matcher: t.matcher)
    }
}

// MARK: - State

private func skillState(_ dir: String) -> ItemState {
    let path = "\(dir)/\(skillFile)"
    guard FileManager.default.fileExists(atPath: path) else { return .missing }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return .unreadable }
    if text == AgentGuide.stub {
        return .current
    }

    return AgentGuide.isOurs(text) ? .outdated : .foreign
}

private func hookState(_ t: AgentTarget, _ path: String) -> ItemState {
    switch loadJSON(path) {
    case .missing:
        return .missing
    case .unreadable:
        return .unreadable
    case .parsed(let root):
        guard hasOurHooks(root) else { return .missing }

        return sameJSON(addingHooks(root, hookSpecs(t)), root) ? .current : .outdated
    }
}

// MARK: - Rows

private struct AgentRow: Encodable {
    let agent: String
    let item: String
    let result: String
    let path: String
    var note: String?
}

private struct AgentReport: Encodable {
    let scope: String
    let dryRun: Bool
    let results: [AgentRow]
}

private func skillRow(_ agents: String, _ dir: String, _ result: String, _ note: String? = nil) -> AgentRow {
    AgentRow(agent: agents, item: "skill", result: result, path: "\(dir)/\(skillFile)", note: note)
}

private func hookRow(_ t: AgentTarget, _ path: String, _ result: String, _ note: String? = nil) -> AgentRow {
    AgentRow(agent: t.agent.rawValue, item: "hook", result: result, path: path, note: note)
}

// MARK: - setup

private func setup(_ ts: [AgentTarget], _ o: AgentOptions) -> [AgentRow] {
    var rows = [AgentRow]()

    for (dir, agents) in bySkillDir(ts) {
        let (action, note) = installSkill(dir, o)
        rows.append(skillRow(agents, dir, action.rawValue, note))
    }
    for t in ts {
        guard let path = t.hookFile else { continue }

        rows.append(installHook(t, path, o))
    }

    return rows + sweepLegacy(o)
}

private func installSkill(_ dir: String, _ o: AgentOptions) -> (AgentAction, String?) {
    let state = skillState(dir)
    switch state {
    case .current:
        return (.unchanged, nil)
    case .unreadable:
        return (.failed, "cannot read it")
    case .foreign where o.overwrite == .keep:
        return (.skipped, "not installed by gctd; --force replaces it")
    default:
        break
    }

    let action: AgentAction = state == .missing ? .installed : (state == .outdated ? .updated : .replaced)
    guard o.mode == .apply else { return (action, nil) }

    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try AgentGuide.stub.write(toFile: "\(dir)/\(skillFile)", atomically: true, encoding: .utf8)
    } catch {
        return (.failed, "\(error)")
    }

    return (action, nil)
}

private func installHook(_ t: AgentTarget, _ path: String, _ o: AgentOptions) -> AgentRow {
    var root = JSONObject()
    switch loadJSON(path) {
    case .unreadable:
        return hookRow(t, path, AgentAction.failed.rawValue, "not valid JSON, left alone; add the hook by hand")
    case .parsed(let found):
        root = found
    case .missing:
        break
    }

    let merged = addingHooks(root, hookSpecs(t))
    guard !sameJSON(merged, root) else { return hookRow(t, path, AgentAction.unchanged.rawValue) }

    let action: AgentAction = hasOurHooks(root) ? .updated : .installed
    guard o.mode == .apply else { return hookRow(t, path, action.rawValue) }

    do {
        try saveJSON(merged, to: path)
    } catch {
        return hookRow(t, path, AgentAction.failed.rawValue, "\(error)")
    }

    return hookRow(t, path, action.rawValue, t.agent == .codex ? codexApproval : nil)
}

// MARK: - remove

private func remove(_ ts: [AgentTarget], _ o: AgentOptions) -> [AgentRow] {
    var rows = [AgentRow]()

    for (dir, agents) in bySkillDir(ts) {
        let (action, note) = dropSkill(dir, o)
        rows.append(skillRow(agents, dir, action.rawValue, note))
    }
    for t in ts {
        guard let path = t.hookFile else { continue }

        rows.append(dropHook(t, path, o))
    }

    return rows + sweepLegacy(o)
}

private func dropSkill(_ dir: String, _ o: AgentOptions) -> (AgentAction, String?) {
    switch skillState(dir) {
    case .missing:
        return (.unchanged, nil)
    case .unreadable:
        return (.failed, "cannot read it")
    case .foreign:
        return (.skipped, "not installed by gctd")
    default:
        break
    }
    guard o.mode == .apply else { return (.removed, nil) }

    let fm = FileManager.default
    do {
        try fm.removeItem(atPath: "\(dir)/\(skillFile)")
        // Drop the dir only when we emptied it; never touch siblings.
        if (try? fm.contentsOfDirectory(atPath: dir))?.isEmpty == true {
            try fm.removeItem(atPath: dir)
        }
    } catch {
        return (.failed, "\(error)")
    }

    return (.removed, nil)
}

private func dropHook(_ t: AgentTarget, _ path: String, _ o: AgentOptions) -> AgentRow {
    let root: JSONObject
    switch loadJSON(path) {
    case .missing:
        return hookRow(t, path, AgentAction.unchanged.rawValue)
    case .unreadable:
        return hookRow(t, path, AgentAction.failed.rawValue, "not valid JSON, left alone")
    case .parsed(let found):
        root = found
    }

    let stripped = removingHooks(root)
    guard !sameJSON(stripped, root) else { return hookRow(t, path, AgentAction.unchanged.rawValue) }
    guard o.mode == .apply else { return hookRow(t, path, AgentAction.removed.rawValue) }

    do {
        try saveJSON(stripped, to: path)
    } catch {
        return hookRow(t, path, AgentAction.failed.rawValue, "\(error)")
    }

    return hookRow(t, path, AgentAction.removed.rawValue, t.agent == .codex ? "Codex asks you to re-approve its other hooks" : nil)
}

// Older installs copied the whole guide into per-agent dirs. Setup and
// remove sweep ours (only ours) so no stale copy competes with the stub.
private func sweepLegacy(_ o: AgentOptions) -> [AgentRow] {
    guard o.scope == .user else { return [] }

    let home = agentHome()
    let dirs = [userConfigDir(.codex), home + "/.config/opencode", home + "/.cursor"]
        .map { "\($0)/skills/\(skillName)" }

    var rows = [AgentRow]()
    for dir in dirs {
        guard skillState(dir) == .outdated else { continue }

        let (action, note) = dropSkill(dir, o)
        rows.append(AgentRow(agent: "legacy", item: "skill", result: action.rawValue,
                             path: "\(dir)/\(skillFile)", note: note))
    }

    return rows
}

// MARK: - status

private func status(_ ts: [AgentTarget]) -> [AgentRow] {
    var rows = [AgentRow]()

    for (dir, agents) in bySkillDir(ts) {
        rows.append(skillRow(agents, dir, skillState(dir).rawValue))
    }
    for t in ts {
        guard let path = t.hookFile else {
            rows.append(hookRow(t, "", ItemState.unsupported.rawValue))
            continue
        }

        rows.append(hookRow(t, path, hookState(t, path).rawValue))
    }

    return rows
}

// MARK: - Output

private func tilde(_ path: String) -> String {
    let home = agentHome()
    guard path.hasPrefix(home + "/") else { return path }

    return "~" + path.dropFirst(home.count)
}

private func pad(_ s: String, _ n: Int) -> String {
    s.padding(toLength: max(n, s.count), withPad: " ", startingAt: 0)
}

// Prints the rows and leaves: 1 when `failing` matches any row.
private func emit(_ rows: [AgentRow], _ o: AgentOptions, failing: (AgentRow) -> Bool) -> Never {
    let dry = o.mode == .dryRun
    switch o.format {
    case .json:
        printJSON(AgentReport(scope: o.scope.rawValue, dryRun: dry, results: rows))
    case .text:
        if dry {
            print("dry run: nothing changed")
        }
        for r in rows {
            let note = r.note.map { "  (\($0))" } ?? ""
            print("\(pad(r.agent, 18)) \(pad(r.item, 6)) \(pad(r.result, 11)) \(tilde(r.path))\(note)")
        }
    }

    exit(rows.contains(where: failing) ? CLIExit.failed.rawValue : CLIExit.ok.rawValue)
}

// MARK: - context

// Where the caller is, for the SessionStart hook: one line, so an agent
// knows it's in GCT and which pane without spending a call to find out.
// Fails open: outside a pane, or with the daemon down, it prints nothing
// and exits 0 rather than wedge session start.
private func agentContext() -> Never {
    guard envVar("GCT_PANE_ID") != nil,
          let c = GCTClient(),
          let w = c.welcome(),
          let pane = resolvePane(w, "self") else { exit(0) }

    let p = paneJSON(w, pane, names: displayNames(w))
    var who = "GCT pane \(p.id.prefix(8)) \"\(p.name)\""
    if let group = p.groupName {
        who += " in group \"\(group)\""
    }
    if p.host != LocalHost {
        who += " on host \(p.host)"
    }

    print("\(who). Run background tasks in panes, not run_in_background: `gctd open name=<task> size=w,h cmd=...`. Guide: `gctd agent show`")
    exit(0)
}

// MARK: - Entry

private func parseOptions(_ args: [String]) -> AgentOptions {
    var o = AgentOptions()
    var it = args.makeIterator()

    while let a = it.next() {
        switch a {
        case "--agent":
            guard let name = it.next() else { bad("--agent needs a name") }

            o.named.append(agentNamed(name))
        case _ where a.hasPrefix("--agent="):
            o.named.append(agentNamed(String(a.dropFirst("--agent=".count))))
        case "--dry-run":
            o.mode = .dryRun
        case "--project":
            o.scope = .project
        case "--force":
            o.overwrite = .replace
        case "--json":
            o.format = .json
        default:
            bad(agentUsage)
        }
    }

    return o
}

private func agentNamed(_ s: String) -> Agent {
    guard let a = Agent(rawValue: s) else {
        bad("unknown agent \(s) (one of: \(Agent.allCases.map(\.rawValue).joined(separator: ", ")))")
    }

    return a
}

// `agent ...` — argv parsing lives here so main.swift's switch stays a flat
// verb dispatch. Every path exits.
func runAgent(_ rest: [String]) -> Never {
    guard let sub = rest.first else { bad(agentUsage) }

    let args = Array(rest.dropFirst())
    switch sub {
    case "show":
        print(AgentGuide.guide)
        exit(CLIExit.ok.rawValue)
    case "context":
        agentContext()
    case "setup", "status":
        let o = parseOptions(args)
        let ts = selected(o, from: .found)
        guard !ts.isEmpty else {
            let all = Agent.allCases.map(\.rawValue).joined(separator: ", ")
            die("no agents found (looked for \(all)); name one with --agent", .notFound)
        }

        if sub == "status" {
            emit(status(ts), o) { $0.result != ItemState.current.rawValue && $0.result != ItemState.unsupported.rawValue }
        }
        emit(setup(ts, o), o) { $0.result == AgentAction.failed.rawValue }
    case "remove":
        let o = parseOptions(args)
        emit(remove(selected(o, from: .all), o), o) { $0.result == AgentAction.failed.rawValue }
    default:
        bad(agentUsage)
    }
}
