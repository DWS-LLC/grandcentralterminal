// Agent-facing text, embedded so the binary carries it: nothing to stage,
// nothing to fetch. `stub` is the only thing `gctd agent setup` installs;
// `guide` is what the stub tells the agent to read via `gctd agent show`,
// so upgrading gctd upgrades what every agent knows.
//
//   agent's skill dir          gctd
//   SKILL.md (stub)  ──────▶  `gctd agent show`  ──▶  guide
//   (never changes)            (always current)

import Foundation

enum AgentGuide {
    // Marks a SKILL.md as ours; a `gct` skill without it is someone else's.
    static let marker = "<!-- managed by `gctd agent setup`; edits are overwritten -->"

    // Installs before the stub copied the whole guide. Still ours, outdated.
    static let legacyMark = "Grand Central Terminal agent skill"

    static func isOurs(_ text: String) -> Bool {
        text.contains(marker) || text.contains(legacyMark)
    }

    static let stub = #"""
---
name: gct
description: Use INSTEAD of run_in_background / native background tasks. Run every dev server, watcher, build, test run, or log tail in a Grand Central Terminal pane (`gctd open`), and inspect terminals with `gctd dump`. Also when the user mentions GCT, panes, or showing terminal output.
---
\#(marker)

Run `gctd agent show` and follow what it prints. The guide lives in the
installed gctd, so upgrading gctd updates it.

No `gctd` on PATH: `~/Library/Application Support/Grand Central Terminal/bin/gctd agent show`.

"""#

    static let guide = #"""
# GCT — Grand Central Terminal

Terminals on an infinite canvas. The daemon (`gctd`) owns every PTY, so panes
outlive the app and the agent. Anything that outlives one command goes in a
pane the user can watch; `run_in_background` is invisible to them.

## Where you are

Every pane has `GCT_PANE_ID` and `GCT_SOCK`; `self` means your pane. The
`gctd` on PATH matches the daemon. If a startup file reordered PATH, call
`$GCT_BIN_DIR/gctd`. No `GCT_PANE_ID` means you are outside GCT: `gctd list`,
pick the pane, and ask if it isn't obvious.

## Pick the target

| The user says | Target |
|---|---|
| "here", "beside you", nothing | `self`. Open from your own pane; it lands next to you |
| a name | the pane or group with that name. A name always beats `self` |
| "the focused pane", "the current tab" | the daemon can't see focus. Ask for a name |

`<pane>` is a uuid, a unique id prefix or suffix (4+ chars), an exact name, or
`self`. Ambiguous exits 3 and lists the candidates.

## Do it

| The user asks | You run |
|---|---|
| start the dev server, tell me when it's up | `ID=$(gctd open name=dev size=480,240 cmd="npm run dev")`, then `gctd dump $ID --strip-ansi limit=2000` until it says ready |
| run the tests, fix what fails | `ID=$(gctd open --keep-open name=tests side=right size=50%,100% cmd="pytest -q")`, `gctd wait $ID for=10m`, then `gctd dump $ID --strip-ansi limit=2000` for the failures, fix, `gctd close $ID` |
| only need pass or fail | `gctd open --wait name=build cmd="make"`. Exit status is the command's |
| type into a REPL (psql) | `gctd send psql "select count(*) from users;"`, then `gctd dump psql --strip-ansi limit=2000` |
| tail a log | `gctd open name=api-log size=900,640 cmd="tail -f api.log"` |
| run it on another machine | add `host=<peer>`; `gctd hosts` lists them |
| ping me when it's done | `gctd notify self "tests are green"` |
| react to events, hold a timer, script several steps | `gctd lua script.lua` or `gctd lua -e '...'`: `gct.on("terminal.child_exited", fn)`, `gct.pane.open{...}`. See docs/scripting.md in the repo |
| close what you opened | `gctd close <id>` for each id you kept, then `gctd list` |
| "top in a narrow pane on the right" | `gctd open name=top side=right size=33%,100% cmd=top` |
| "put it below / to the left" | `side=below size=100%,30%`, `side=left size=40%,100%` |
| make the text bigger or smaller | `gctd font +2`, `gctd font -2`, `gctd font reset` (add a pane to change only it) |
| switch to session "X" | `gctd session X` (`local` or a name from `gctd hosts`). The canvas then hears only X's daemon, so to switch back run `gctd session local` from a pane on X |

`size=w,h` is in world points: `480,240` for a task, `900,640` for a log.
`size=33%,100%` is a share of your own pane's width and height. `side=` picks
which edge of your pane it lands on: `right` (default), `left`, `above`,
`below`. Both need you to be in a pane (or `parent=`), and the daemon still
keeps clear of everything else. Omit `size` for an interactive shell (copies
your pane).
`open` never takes focus from the user, so a server can start behind their
work. `gctd focus <id>` brings one forward when they ask.

`cmd=` runs through the
login shell, so `&&`, pipes and quotes work. Omit `cmd=` for a plain shell.

A pane closes when its command exits and takes the scrollback with it. Add
`--keep-open` when you need to read the output afterward: the pane stays,
dimmed with a ✕, and `gctd dump` still works. It goes when you `gctd close` it,
or after `keep-open-ttl` in config.toml (default 7d, `0` = until closed).
Don't leave them lying around.

`gctd wait <pane> for=10m` blocks until the program ends and exits with its
status, or exits 124 when the time is up (the pane keeps running). `for=` also
works on `open --wait`.

## Example: tests in a split

Runs beside you, closes itself on green, zooms and stays open on red or on
timeout.

```sh
#!/bin/sh
cmd="${1:-make test}"

id=$(gctd open --keep-open name=tests side=right size=50%,100% cmd="$cmd")

if ! gctd wait "$id" for=10m; then
  gctd do zoom-pane "$id"
  exit 1
fi
gctd close "$id"
```

## Rules

1. `gctd open`, never `run_in_background`, for anything that outlives one command.
2. Always `name=`, named for the task. Tell the user the name so they can look.
3. One group per task: `gctd group $A $B name=<task>`. Panes opened from a
   grouped pane join its group.
4. `dump --strip-ansi` before you claim what a pane printed. Raw VT lies.
5. `send` is keystrokes. One-shot commands go through `open cmd=`; `send` drives
   programs already running. `--no-newline` skips Enter; `\xHH` sends any byte
   (`\x03` is ^C).
6. Keep every id you open. Close your panes (and empty groups, and
   `--keep-open` ones) when the work lands; a server the user still needs stays, named and grouped.
   `gctd list` before you finish.
7. Never `gctd stop`: it kills the daemon and every pane.
8. Never `rect=` a pane across the canvas. Place with `side=` and `size=`.

`gctd help` lists every command; `gctd help <command>` has the details.
"""#
}
