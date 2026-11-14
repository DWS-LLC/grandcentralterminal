// gctd help text: one table feeds both `gctd help` and `gctd help <cmd>`
// (also `gctd <cmd> --help`), so a synopsis is written exactly once.

import Foundation

struct CommandHelp {
    let name: String
    let synopsis: String
    let summary: String
    var notes: String = ""
}

private let paneRef = "<pane> is a uuid (or pane:<uuid>), a unique id prefix or suffix (4+ chars), an exact name, or self."

let commandHelp: [CommandHelp] = [
    CommandHelp(name: "stop", synopsis: "stop",
                summary: "kill daemon + panes"),
    CommandHelp(name: "version", synopsis: "version",
                summary: "print the gctd version (--version)"),
    CommandHelp(name: "help", synopsis: "help [command]",
                summary: "all commands, or the details of one"),

    CommandHelp(name: "open",
                synopsis: "open [cwd=..] [name=..] [cmd=..] [group=..] [parent=<pane>] [size=w,h] [rect=x,y,w,h] [host=<peer>] [--wait]",
                summary: "open a pane beside focused/origin, print its id",
                notes: """
                parent= wires it to that pane, whoever calls.
                host= runs it on a [host.<peer>] machine.
                --wait blocks until the pane's program ends and exits with its status
                (id is printed first), like `rex run --wait`.
                """),
    CommandHelp(name: "tie", synopsis: "tie <parent> <child>... [at=0.4]",
                summary: "tie the cables from <parent> to each <child> into one bundle; prints the tie id"),
    CommandHelp(name: "untie", synopsis: "untie <tie>",
                summary: "remove a tie"),
    CommandHelp(name: "move", synopsis: "move <pane> rect=x,y,w,h",
                summary: "place a pane (overlap rules still apply)"),
    CommandHelp(name: "list", synopsis: "list [--json]",
                summary: "panes + groups, one per line (alias: status)",
                notes: """
                --json prints one object: panes, guests, groups, peers, ties,
                with full ids and fixed keys. Parse that, not the lines.
                """),
    CommandHelp(name: "inspect", synopsis: "inspect [<pane>] [--json]",
                summary: "everything the daemon knows about one pane (default: self)",
                notes: "name, state, host, cwd, foreground process, repo, group, parent, placement."),
    CommandHelp(name: "hosts", synopsis: "hosts [--json]",
                summary: "peer machines this daemon dials, and whether each link is up"),
    CommandHelp(name: "wait", synopsis: "wait <pane>",
                summary: "block until a pane's program ends; exit with its status",
                notes: """
                Exit(n) is n, death by signal is 128+signal. A pane closed by a
                client has no status: exit 1. Panes that ended recently (last 256)
                still answer; older or unknown ones exit 3.
                """),
    CommandHelp(name: "dump", synopsis: "dump <pane> [limit=N] [--strip-ansi]",
                summary: "scrollback snapshot (id prefix, name, or self)"),
    CommandHelp(name: "send", synopsis: "send <pane> [text]... [--no-newline] [--paste]",
                summary: "type text into a pane (appends newline; --no-newline to skip; --paste brackets it; \\xHH/\\e/\\n/\\t escapes; no text reads stdin)"),
    CommandHelp(name: "notify", synopsis: "notify <pane> [title=..] <text>...  |  notify <pane> --hook",
                summary: "desktop notification, click focuses the pane (--hook: Claude Code hook payload on stdin)"),
    CommandHelp(name: "close", synopsis: "close <pane>",
                summary: "terminate a pane"),
    CommandHelp(name: "rename", synopsis: "rename <pane> name=..",
                summary: "name a pane"),
    CommandHelp(name: "group", synopsis: "group <pane>... name=.. [color=#..]",
                summary: "group panes (2+), print group id"),
    CommandHelp(name: "ungroup", synopsis: "ungroup <group>",
                summary: "dissolve a group (panes survive)"),
    CommandHelp(name: "focus", synopsis: "focus <pane>",
                summary: "focus + center a pane on the canvas"),
    CommandHelp(name: "camera", synopsis: "camera [pane] [x=.. y=..] [zoom=..] [dur=..]",
                summary: "glide the camera to a world point or pane"),
    CommandHelp(name: "do", synopsis: "do <action> [pane] [dur=..]",
                summary: "run a keybind action (fit-all, zoom-pane..)"),
    CommandHelp(name: "agent-setup", synopsis: "agent-setup print|install|uninstall|context",
                summary: "skill install + live pane context for hooks (--harness=claude,codex,opencode,cursor,cursor-agents; install --hooks merges a Claude SessionStart hook)"),
]

private let helpFooter = """

      <pane>    \(paneRef)
      Env:      GCT_PANE_ID (this pane), GCT_SOCK (this daemon), GCT_BIN_DIR (the gctd
                matching this daemon, first on PATH inside panes)
      Exit:     0 ok, 1 failed, 2 bad command line, 3 target missing or ambiguous,
                4 daemon unreachable; wait/open --wait return the program's status
    """

private func indented(_ text: String, by pad: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "" : pad + $0 }
        .joined(separator: "\n")
}

// Text for `help [cmd]`; nil when cmd is not a command.
func helpText(_ command: String?) -> String? {
    guard let command else {
        var out = "usage: gctd <command> [args]   (no command runs the daemon itself)\n\n"
        for c in commandHelp {
            out += "    \(c.synopsis)\n\(indented(c.summary, by: "          "))\n"
        }
        return out + helpFooter + "\n"
    }

    let key = command == "--version" ? "version" : (command == "status" ? "list" : command)
    guard let c = commandHelp.first(where: { $0.name == key }) else { return nil }

    var out = "gctd \(c.synopsis)\n\n  \(c.summary)\n"
    if !c.notes.isEmpty { out += "\n" + indented(c.notes, by: "  ") + "\n" }
    if c.synopsis.contains("<pane>") { out += "\n  \(paneRef)\n" }
    return out
}

func printHelp(_ command: String?) -> Never {
    guard let text = helpText(command) else {
        bad("no help for \(command ?? ""); try `gctd help`")
    }
    fputs(text, stdout)
    exit(CLIExit.ok.rawValue)
}
