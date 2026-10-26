// gctd agent-setup — how an agent finds out about GCT.
//
// `agent-setup print`   show where the skill installs per harness.
// `agent-setup install [--harness=...] [--hooks] [--yes]`
//                       copy SKILL.md into harness skill dirs, optionally
//                       merge a SessionStart hook (Claude) emitting live
//                       pane state via `gctd agent-setup context`, plus
//                       Notification/Stop hooks that call `gctd notify`.
// `agent-setup uninstall [--harness=...]`
//                       remove installed skill dirs (+ our hook entry).
// `agent-setup context [--json]`
//                       live pane/group state for hooks and prompts.
//
// Installs from disk: the skill ships beside the gctd binary
// ($SUPPORT/skills/gct/SKILL.md, staged by scripts/build.sh); repo
// checkout fallback is <repo>/SKILL.md next to the source tree.
// No network, no GitHub fetch — the binary carries the skill.

import Foundation

// MARK: - Skill source

enum AgentSkill {
    // Skill dir beside the binary ($SUPPORT/skills/gct/SKILL.md once
    // staged) or at the repo root when running from a checkout.
    static func text() -> String? {
        for p in candidatePaths() {
            if let s = try? String(contentsOfFile: p, encoding: .utf8),
               !s.isEmpty { return s }
        }
        return nil
    }

    // Exposed for `print` so agents can read/copy it without installing.
    static func candidatePaths() -> [String] {
        var out = [String]()
        // argv[0] is a bare "gctd" when launched via PATH, so ask the OS
        // for the real binary and follow the /usr/local/bin symlink.
        var self0 = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        if !self0.hasPrefix("/") {
            self0 = FileManager.default.currentDirectoryPath + "/" + self0
        }
        self0 = URL(fileURLWithPath: self0).resolvingSymlinksInPath().path
        let dir = (self0 as NSString).deletingLastPathComponent
        out.append(dir + "/../skills/gct/SKILL.md")
        out.append(dir + "/skills/gct/SKILL.md")
        // Repo checkout: Sources/Daemon -> root.
        let checkout = ((dir as NSString).deletingLastPathComponent as NSString)
            .deletingLastPathComponent
        out.append((checkout as NSString).appendingPathComponent("SKILL.md"))
        return out
    }
}

// MARK: - Harness targets

// Every skill dir we install into. `hook` = whether this harness has a
// per-session context hook we can merge (today: Claude SessionStart only);
// the rest get the skill file alone. Paths verified against vendor docs;
// Codex needs [features] skills=true (flagged in `print`).
struct Harness: Sendable {
    let name: String       // --harness= id
    let skillDir: String   // <dir>/gct/SKILL.md parent
    let hook: Bool
}

// $HOME first (agents/sandboxes override it; also makes isolated-HOME
// testing possible), passwd fallback. NSHomeDirectory() ignores $HOME.
func agentHome() -> String {
    if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return h }
    return NSHomeDirectory()
}

func agentHarnesses() -> [Harness] {
    let home = agentHome()
    return [
        Harness(name: "claude", skillDir: home + "/.claude/skills/gct", hook: true),
        Harness(name: "codex", skillDir: home + "/.codex/skills/gct", hook: false),
        Harness(name: "opencode", skillDir: home + "/.config/opencode/skills/gct", hook: false),
        Harness(name: "cursor", skillDir: home + "/.cursor/skills/gct", hook: false),
        Harness(name: "cursor-agents", skillDir: home + "/.agents/skills/gct", hook: false),
    ]
}

func harness(named: String) -> Harness? {
    agentHarnesses().first { $0.name == named }
}

// MARK: - print

// Machine-readable target list + the skill text, so an agent can install
// by hand (or into a harness we don't know) without running install.
func agentSetupPrint() {
    print("skill: gct")
    for h in agentHarnesses() {
        print("target \(h.name) \(h.skillDir)/SKILL.md hooks=\(h.hook ? "session-start" : "none")")
    }
    print("codex-note: enable with [features] skills=true in ~/.codex/config.toml")
    if let first = AgentSkill.candidatePaths().first {
        print("source: \(first)")
    }
    guard let text = AgentSkill.text() else {
        die("skill source not found (looked in \(AgentSkill.candidatePaths().joined(separator: ", ")))")
    }
    print("---")
    fputs(text, stdout)
}

// MARK: - context

// Live pane/group summary for hooks and prompts. Human-readable default
// (fits a SessionStart additionalContext budget); --json for tooling.
func agentSetupContext(json: Bool) {
    guard let c = GCTClient() else {
        // Daemon down: hooks must fail open (empty context, rc 0), never
        // wedge session start.
        if json { print("{\"panes\":[],\"groups\":[],\"running\":false}") }
        exit(0)
    }
    guard let w = c.welcome() else { exit(0) }
    if json {
        var panes = [[String: String]]()
        for p in w.panes {
            panes.append(["id": p.id.uuid.uuidString, "name": p.name ?? "Terminal",
                          "cwd": p.cwd, "exited": p.exited ? "true" : "false"])
        }
        var groups = [[String: Any]]()
        for g in w.groups {
            groups.append(["id": g.id.uuid.uuidString, "name": g.name ?? "",
                           "members": g.members.map(\.description)])
        }
        let obj: [String: Any] = ["running": true, "panes": panes, "groups": groups]
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: data, encoding: .utf8) { print(s) }
        exit(0)
    }
    if w.panes.isEmpty { print("GCT: daemon running, no panes."); exit(0) }
    print("GCT: \(w.panes.count) pane(s), \(w.groups.count) group(s). Run background tasks in GCT panes, not run_in_background: `gctd open name=<task> size=480,240 cmd=...`, inspect with `gctd dump <id> --strip-ansi`.")
    for p in w.panes {
        print("pane \(String(p.id.uuid.uuidString.prefix(8))) \(p.name ?? "Terminal") cwd=\(p.cwd)\(p.exited ? " exited" : "")")
    }
    for g in w.groups {
        print("group \(String(g.id.uuid.uuidString.prefix(8))) \(g.name ?? "") members=\(g.members.count)")
    }
    exit(0)
}

// MARK: - install / uninstall

// Minimal JSON merge for ~/.claude/settings.json: parse with
// JSONSerialization, insert our SessionStart entry, write back. Never
// touches other keys; refuses to write unparseable files (prints the
// entry for manual install instead).
// SessionStart budget for `context`: normally milliseconds; the timeout
// bounds a wedged daemon. Expiry discards output, and SessionStart can't
// block, so the session just proceeds without context.
let claudeHookTimeout = 15

func mergeClaudeHook(bin: String) -> Bool {
    let path = agentHome() + "/.claude/settings.json"
    let fm = FileManager.default
    var root: [String: Any] = [:]
    if fm.fileExists(atPath: path) {
        guard let data = fm.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            fputs("settings.json unparseable; add the hook by hand:\n\(claudeHookEntry(bin: bin))\n", stderr)
            return false
        }
        root = dict
    }
    var hooks = (root["hooks"] as? [String: Any]) ?? [:]
    var starts = (hooks["SessionStart"] as? [[String: Any]]) ?? []
    let entry = claudeHookEntryObject(bin: bin)
    // Idempotent: skip when our command is already registered.
    let ours = entry["hooks"] as? [[String: Any]]
    let ourCmd = (ours?.first?["command"] as? String) ?? ""
    var hasStart = false
    for s in starts {
        for h in (s["hooks"] as? [[String: Any]]) ?? [] {
            if (h["command"] as? String) == ourCmd { hasStart = true }
        }
    }
    // Migrate: older installs wrote the staged path (contains spaces —
    // hook runners choke on it) or the bare command (an unexecable binary
    // then fails SessionStart with a non-blocking error every session).
    // Rewrite any gctd context entry in place instead of appending a duplicate.
    var migrated = hasStart
    starts = starts.map { group in
        var group = group
        if var hs = group["hooks"] as? [[String: Any]] {
            for j in hs.indices {
                if let cmd = hs[j]["command"] as? String,
                   cmd.contains("agent-setup context"),
                   cmd.contains("gctd"), cmd != ourCmd {
                    hs[j]["command"] = ourCmd
                    hs[j]["timeout"] = claudeHookTimeout
                    migrated = true
                }
            }
            group["hooks"] = hs
        }
        return group
    }
    if !migrated {
        starts.append(entry)
    }
    hooks["SessionStart"] = starts
    mergeNoticeHooks(&hooks, bin: bin)
    root["hooks"] = hooks
    guard let data = try? JSONSerialization.data(
        withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return false }
    do {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return true
    } catch {
        fputs("write failed (\(error)); add the hook by hand:\n\(claudeHookEntry(bin: bin))\n", stderr)
        return false
    }
}

// Claude events that should ping the desktop: it needs input, or it is done.
let claudeNoticeEvents = ["Notification", "Stop"]
let claudeNoticeTimeout = 10

func claudeNoticeCommand(bin: String) -> String {
    "\(bin) notify self --hook || exit 0"
}

// Same fail-open rules as SessionStart; `notify --hook` exits 0 itself
// outside a GCT pane or without a message.
func mergeNoticeHooks(_ hooks: inout [String: Any], bin: String) {
    let cmd = claudeNoticeCommand(bin: bin)

    for event in claudeNoticeEvents {
        var groups = (hooks[event] as? [[String: Any]]) ?? []
        let present = groups.contains { group in
            ((group["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String) == cmd }
        }
        if present { continue }

        groups.append(["matcher": "", "hooks": [["type": "command", "command": cmd,
                                                  "timeout": claudeNoticeTimeout]]])
        hooks[event] = groups
    }
}

func claudeHookEntryObject(bin: String) -> [String: Any] {
    // `|| exit 0`: fail open. An unexecable binary (bad signature, missing
    // path) exits nonzero with empty stderr, which Claude surfaces as a
    // SessionStart hook error every session — swallow it instead.
    ["matcher": "", "hooks": [["type": "command",
                               "command": "\(bin) agent-setup context || exit 0",
                               "timeout": claudeHookTimeout]]]
}

func claudeHookEntry(bin: String) -> String {
    "{\"hooks\":{\"SessionStart\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"\(bin) agent-setup context || exit 0\",\"timeout\":\(claudeHookTimeout)}]}]}}"
}

func agentSetupInstall(harnesses: [Harness], hooks: Bool, yes: Bool) {
    guard let text = AgentSkill.text() else {
        die("skill source not found (looked in \(AgentSkill.candidatePaths().joined(separator: ", ")))")
    }
    // Hook command prefers /usr/local/bin/gctd: no spaces (hook runners
    // that split on whitespace choke on "Application Support"), stable
    // across rebuilds. Falls back to the invoked binary when the symlink
    // is absent (and migrateHookCommand rewrites stale entries on the
    // next --hooks install).
    var self0 = "/usr/local/bin/gctd"
    if !FileManager.default.isExecutableFile(atPath: self0) {
        self0 = CommandLine.arguments.first ?? "gctd"
        if !self0.hasPrefix("/") {
            self0 = FileManager.default.currentDirectoryPath + "/" + self0
        }
    }
    if !yes {
        print("will install GCT skill into:")
        for h in harnesses { print("  \(h.skillDir)/SKILL.md") }
        if hooks {
            print("plus Claude SessionStart hook: \(self0) agent-setup context")
            print("plus Claude Notification + Stop hooks: \(claudeNoticeCommand(bin: self0))")
        }
        fputs("re-run with --yes to apply\n", stderr)
        exit(2)
    }
    let fm = FileManager.default
    for h in harnesses {
        do {
            try fm.createDirectory(atPath: h.skillDir, withIntermediateDirectories: true)
            try text.write(toFile: h.skillDir + "/SKILL.md", atomically: true, encoding: .utf8)
            print("installed \(h.skillDir)/SKILL.md")
        } catch {
            die("install into \(h.skillDir) failed: \(error)")
        }
    }
    if hooks {
        guard harnesses.contains(where: { $0.name == "claude" }) else {
            die("--hooks needs the claude harness selected")
        }
        if mergeClaudeHook(bin: self0) {
            print("merged SessionStart, Notification, Stop hooks into \(agentHome())/.claude/settings.json")
        } else {
            die("hook merge failed (manual entry printed above)")
        }
    }
    exit(0)
}

func agentSetupUninstall(harnesses: [Harness]) {
    let fm = FileManager.default
    for h in harnesses {
        let dir = h.skillDir
        if fm.fileExists(atPath: dir + "/SKILL.md") {
            try? fm.removeItem(atPath: dir + "/SKILL.md")
            // Drop the dir when we emptied it; never touch siblings.
            if (try? fm.contentsOfDirectory(atPath: dir))?.isEmpty == true {
                try? fm.removeItem(atPath: dir)
            }
            print("removed \(dir)/SKILL.md")
        } else {
            print("absent \(dir)/SKILL.md")
        }
    }
    // Hook entries stay (cheap, fail-open, and shared files deserve a
    // manual edit); say so explicitly.
    if harnesses.contains(where: { $0.name == "claude" }) {
        fputs("note: GCT hook entries left in \(agentHome())/.claude/settings.json (remove by hand)\n", stderr)
    }
    exit(0)
}

// `agent-setup ...` — argv parsing lives here so main.swift's switch stays
// a flat verb dispatch. Every path exits (directly or via die()).
func runAgentSetup(_ rest: [String]) {
    var args = rest
    var harnessNames = [String]()
    var hooks = false
    var yes = false
    var json = false
    var sub: String?
    for a in args {
        if a.hasPrefix("--harness=") {
            harnessNames.append(contentsOf: a.dropFirst("--harness=".count).split(separator: ",").map(String.init))
        } else if a == "--hooks" { hooks = true }
        else if a == "--yes" { yes = true }
        else if a == "--json" { json = true }
        else if sub == nil { sub = a }
        else { die("unexpected \(a)") }
    }
    let selected: [Harness]
    if harnessNames.isEmpty {
        selected = agentHarnesses()
    } else {
        selected = harnessNames.map {
            guard let h = harness(named: $0) else {
                die("unknown harness \($0) (one of: \(agentHarnesses().map(\.name).joined(separator: ", ")))")
            }
            return h
        }
    }
    switch sub {
    case nil, "print": agentSetupPrint()
    case "install": agentSetupInstall(harnesses: selected, hooks: hooks, yes: yes)
    case "uninstall": agentSetupUninstall(harnesses: selected)
    case "context": agentSetupContext(json: json)
    default: die("agent-setup print|install|uninstall|context [--harness=..] [--hooks] [--yes] [--json]")
    }
}
