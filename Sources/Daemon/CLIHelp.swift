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
                synopsis: "open [cwd=..] [name=..] [cmd=..] [group=..] [parent=<pane>] [side=right|left|above|below] [size=w,h|w%,h%] [rect=x,y,w,h] [host=<peer>] [--keep-open] [--wait [for=<span>]]",
                summary: "open a pane beside focused/origin, print its id",
                notes: """
                side= the caller's edge it lands on (default right).
                size= world points, or a share of the caller: size=33%,100% beside
                a 900x560 caller is 297x560. Needs a calling pane or parent=.
                The pane never takes focus (unless nothing is focused); `gctd focus` does.
                parent= wires it to that pane, whoever calls.
                host= runs it on a [host.<peer>] machine.
                --wait blocks until the pane's program ends and exits with its status
                (id is printed first), like `rex run --wait`. for=10m gives up after
                that long and exits 124.
                --keep-open leaves the pane (dimmed, ✕) with its scrollback once the
                program ends, so you can dump it. It goes on `gctd close`, or after
                keep-open-ttl in config.toml (default 7d, 0 = until closed).
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
    CommandHelp(name: "wait", synopsis: "wait <pane> [for=<span>]",
                summary: "block until a pane's program ends; exit with its status",
                notes: """
                Exit(n) is n, death by signal is 128+signal. A pane closed by a
                client has no status: exit 1. Panes that ended recently (last 256)
                still answer; older or unknown ones exit 3.
                for=90s, 10m, 2h gives up after that long and exits 124; the pane keeps running.
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
    CommandHelp(name: "font", synopsis: "font <+N|-N|reset> [pane]",
                summary: "grow or shrink terminal text (points) on every pane, or one; lasts until relaunch"),
    CommandHelp(name: "session", synopsis: "session <name>",
                summary: "show a machine's canvas: local or a [host.<name>] (`gctd hosts`)"),
    CommandHelp(name: "agent", synopsis: "agent setup|status|remove|show|context [--agent NAME]... [--project] [--dry-run] [--force] [--json]",
                summary: "teach coding agents about GCT: a skill and session hooks",
                notes: """
                setup    install both for each agent found (claude, codex, opencode, pi); safe to rerun
                status   current, outdated, missing, foreign, unreadable or unsupported; exit 1 unless all current
                remove   take both back out, for every known agent
                show     print the guide the installed skill points at (upgrading gctd updates it)
                context  where the caller is, one line (what the SessionStart hook prints)
                --agent NAME  only that agent, found or not; repeat for several
                --project     the current repository instead of your account
                --dry-run     report what would change
                --force       replace a `gct` skill gctd didn't install
                --json        machine-readable result
                """),
]

private let helpFooter = """

      <pane>    \(paneRef)
      Env:      GCT_PANE_ID (this pane), GCT_SOCK (this daemon), GCT_BIN_DIR (the gctd
                matching this daemon, first on PATH inside panes)
      Exit:     0 ok, 1 failed, 2 bad command line, 3 target missing or ambiguous,
                4 daemon unreachable, 124 wait for= timed out; wait/open --wait
                return the program's status
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
