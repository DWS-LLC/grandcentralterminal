// Auto names for panes that have no custom name.
//
//   proc / cwd / title / repo ──► label ──► unique across the canvas
//
//   idle shell        gct            repo, or the shortest dir that
//                     gct/Canvas     tells it apart from every other
//   editor, pager     nvim · gct     pane (tmux-window-name's trick)
//   other program     make -j8 · gct
//   coding agent      claude · gct · pip fit      task = program's title
//   linked worktree   gct@feat-x
//
// Pure and deterministic: same panes in, same names out. Stability over
// time (a `ls` blip must not rename anything) is the caller's job; the
// daemon only reports a foreground command once it holds for two polls.
//
// Pure string math, same as Orbit: no AppKit, runs in the CLI.

import Foundation

public enum AutoName {
    public struct Pane: Sendable {
        public var id: PaneID
        public var cwd: String
        public var proc: String?
        public var title: String?
        public var repoRoot: String?
        public var worktree: String?
        public init(id: PaneID, cwd: String, proc: String? = nil, title: String? = nil,
                    repoRoot: String? = nil, worktree: String? = nil) {
            self.id = id; self.cwd = cwd; self.proc = proc; self.title = title
            self.repoRoot = repoRoot; self.worktree = worktree
        }
    }

    private static let shells: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "login",
    ]
    // Interpreters (shells too, given a script): the script they run is
    // the program.
    private static let launchers: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "perl", "npx", "bunx", "uv", "env",
    ]
    private static let agents: Set<String> = [
        "claude", "codex", "opencode", "cursor-agent", "aider", "gemini", "amp", "goose",
        "crush", "droid",
    ]
    // Where the program runs matters more than its arguments.
    private static let dirPrograms: Set<String> = [
        "nvim", "vim", "vi", "nano", "emacs", "hx", "helix", "micro", "git", "lazygit",
        "tig", "gitui", "less", "man", "htop", "btop", "top",
    ]
    // The cwd is a local detail; the remote end is what matters.
    private static let dirless: Set<String> = ["ssh", "mosh", "telnet"]
    // Titles that say nothing about the task.
    private static let genericTitles: Set<String> = [
        "claude code", "claude", "codex", "openai codex", "opencode", "gemini", "aider",
    ]

    private static let separator = " · "
    private static let ellipsis = "…"
    private static let maxArgs = 2
    private static let maxArgChars = 24
    private static let maxTaskChars = 28

    public static func names(_ panes: [Pane], home: String) -> [PaneID: String] {
        let dirs = dirLabels(panes, home: home)
        var out = [PaneID: String]()

        for p in panes {
            let dir = dirs[p.cwd] ?? p.cwd
            out[p.id] = compose(p, dir: dir)
        }
        return out
    }

    // MARK: Compose

    private static func compose(_ p: Pane, dir: String) -> String {
        guard let cmd = Command(p.proc) else { return dir }
        if shells.contains(cmd.name) { return dir }

        if agents.contains(cmd.name) {
            return ([cmd.name, dir, task(p.title)].compactMap { $0 }).joined(separator: separator)
        }

        if dirPrograms.contains(cmd.name) {
            return [cmd.name, dir].joined(separator: separator)
        }

        let shown = ([cmd.name] + cmd.args.prefix(maxArgs).map(shortArg)).joined(separator: " ")
        if dirless.contains(cmd.name) { return shown }
        return [shown, dir].joined(separator: separator)
    }

    // "⠂ Fix pip bug" -> "Fix pip bug"; spinner glyphs and the agent's own
    // name carry no task.
    private static func task(_ title: String?) -> String? {
        guard let title else { return nil }

        let text = title.drop { !$0.isLetter && !$0.isNumber }
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !genericTitles.contains(text.lowercased()) else { return nil }
        return clip(text, maxTaskChars)
    }

    private static func shortArg(_ arg: String) -> String {
        let isPath = arg.contains("/") && !arg.hasPrefix("-") && !arg.contains("=")
        let base = isPath ? (arg as NSString).lastPathComponent : arg
        return clip(base, maxArgChars)
    }

    private static func clip(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max - 1)) + ellipsis
    }

    // MARK: Command line

    private struct Command {
        var name: String
        var args: [String]

        // "-zsh" -> zsh; "node /x/bin/codex --foo" -> codex --foo.
        init?(_ line: String?) {
            guard let line else { return nil }

            var words = line.split(separator: " ").map(String.init)
            guard let first = words.first else { return nil }
            words.removeFirst()

            var name = Self.base(first)
            let runsScript = AutoName.launchers.contains(name) || AutoName.shells.contains(name)
            if runsScript, let script = words.first, !script.hasPrefix("-") {
                name = Self.base(script)
                words.removeFirst()
            }

            self.name = name
            self.args = words
        }

        private static func base(_ word: String) -> String {
            let trimmed = word.drop { $0 == "-" }
            return (String(trimmed) as NSString).lastPathComponent
        }
    }

    // MARK: Directories

    // One label per distinct cwd, as short as it can be while no two
    // different dirs share it:  ~/a/api + ~/b/api  ->  a/api, b/api.
    private static func dirLabels(_ panes: [Pane], home: String) -> [String: String] {
        var specs = [String: DirSpec]()
        for p in panes where specs[p.cwd] == nil {
            specs[p.cwd] = DirSpec(p, home: home)
        }

        let keys = specs.keys.sorted()
        var depth = [String: Int]()
        for k in keys { depth[k] = 1 }

        // Each pass lengthens only the labels that still collide.
        let maxPasses = (specs.values.map(\.rootComps.count).max() ?? 1) + 1
        for _ in 0..<maxPasses {
            var byLabel = [String: [String]]()
            for k in keys {
                byLabel[specs[k]!.label(depth: depth[k]!), default: []].append(k)
            }

            var grew = false
            for group in byLabel.values where group.count > 1 {
                for k in group where depth[k]! < specs[k]!.rootComps.count {
                    depth[k]! += 1
                    grew = true
                }
            }
            if !grew { break }
        }

        return Dictionary(uniqueKeysWithValues: keys.map { ($0, specs[$0]!.label(depth: depth[$0]!)) })
    }

    // A cwd split into the part that names it (the repo root, or the whole
    // path) and the part below it.
    private struct DirSpec {
        var rootComps: [String]
        var sub: [String]
        var branch: String?

        init(_ p: Pane, home: String) {
            let root = p.repoRoot ?? p.cwd
            rootComps = Self.comps(root, home: home)
            branch = p.repoRoot == nil ? nil : p.worktree
            sub = []

            guard p.repoRoot != nil, p.cwd.hasPrefix(root), p.cwd != root else { return }
            let rest = p.cwd.dropFirst(root.count)
            sub = rest.split(separator: "/").map(String.init)
        }

        func label(depth: Int) -> String {
            var tail = Array(rootComps.suffix(depth))
            if let branch, !tail.isEmpty { tail[tail.count - 1] += "@" + branch }

            switch sub.count {
            case 0: break
            case 1: tail.append(sub[0])
            default: tail.append(AutoName.ellipsis); tail.append(sub[sub.count - 1])
            }
            return tail.joined(separator: "/")
        }

        // "/Users/me/p/gct" under home "/Users/me" -> ["~","p","gct"].
        private static func comps(_ path: String, home: String) -> [String] {
            if path == home { return ["~"] }
            if !home.isEmpty, path.hasPrefix(home + "/") {
                return ["~"] + path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
            }
            let parts = path.split(separator: "/").map(String.init)
            return parts.isEmpty ? ["/"] : parts
        }
    }
}
