---
name: gct
description: Use INSTEAD of run_in_background / native background tasks. Run every dev server, watcher, build, test run, or log tail in a Grand Central Terminal pane (`gctd open`), and inspect terminals with `gctd dump`. Also when the user mentions GCT, panes, or showing terminal output.
---
# GCT — Grand Central Terminal agent skill

Use GCT panes, not `run_in_background`, for anything that outlives one
command: grouped, no time limits, and the user can watch on the infinite
canvas. Native background tasks are invisible to them. The daemon
(`gctd`) owns every PTY, so panes survive app restarts and agent exits.

Binary: `~/Library/Application Support/Grand Central Terminal/bin/gctd`
(or `gctd` on PATH). Inside a GCT pane, `GCT_SOCK`/`GCT_PANE_ID` are already
set — `gctd` just works. Outside, it targets the live daemon by default.
Use the staged binary (same build as the daemon); a newer CLI against an
older daemon may hang on new subcommands (`dump`) — relaunch the app to
refresh a stale daemon.

## Open a terminal next to the working one

```sh
# new pane in the free air around the calling pane (inherits group when the caller is grouped)
gctd open name=build cmd="make -j8"
ID=$(gctd open cwd=/tmp/work name=tests cmd="pytest -q")
gctd open name=api-log size=900,640 cmd="tail -f api.log"
```

Keep it nearby: run `gctd open` from your own pane so the new window orbits
you, clear of other panes. Don't `rect=` it across the canvas.

Size it for the job (world points, `size=w,h`; the default copies your pane):

| job | size |
| --- | --- |
| background task: build, test run, dev server | `size=480,240` |
| log tail, watcher output | `size=900,640` |
| interactive shell, REPL | omit, keep your pane's size |

`open` prints the new pane id. `cmd=` runs through the login shell, so
real shell syntax works (`&&`, pipes, quotes). The pane exits when the
command does — append `; exec zsh` (or `|| exec zsh`) to keep it open
for inspection afterward. Omit `cmd=` for a persistent interactive
shell. `group=<name|id>` joins that group.

## Inspect terminal state

```sh
gctd list                              # panes + groups
gctd dump self                         # this pane's scrollback
gctd dump $ID limit=4000 --strip-ansi  # last 4KB, readable text
gctd send $ID "make test"              # type into the pane (adds newline)
gctd send $ID --no-newline "\x1b[A"    # up-arrow, no newline
gctd send $ID --no-newline '\x03'      # ^C (any byte: \xHH)
gctd dump $A --strip-ansi | gctd send $B --paste   # no text = stdin; --paste brackets it
gctd notify self "tests are green"     # desktop ping, click focuses this pane
```

`dump` ships the raw VT ring tail (8 MiB retained); `--strip-ansi` scrubs
escape sequences for reading. `[truncated: ...]` on stderr means the ring
held more than `limit` asked for. Poll `dump` to follow a background task —
no timeouts, no lost output.

Pane ids: uuid prefix, exact `name=`, or `self` (= `$GCT_PANE_ID`).

## Organize: group correlated windows

Group windows that belong together so the user reads them as one unit —
one group per task, feature, or service, with a real name:

```sh
gctd group $SERVER $LOGS name=foldsite color=#3b82f6
gctd group $BUILD $TESTS name=ci color=#22c55e
gctd focus $SERVER   # put the group on screen when it needs attention
```

Panes opened from inside a grouped pane join its group automatically.
`gctd open group=<name>` joins explicitly. Ungrouped panes are strays —
if two of your panes correlate, group them.

## Subagents: tail progress in small windows

When you fan out subagents (Task tool, background runs), give each one
its own small named pane in a shared group instead of letting output
vanish into the transcript:

```sh
G=$(gctd group $A $B name=agents color=#a855f7)
# each subagent reports into its pane: `gctd send $PANE "<progress>"`
# poll with `gctd dump $PANE limit=1000 --strip-ansi`
```

One glance at the group shows every worker's state; `dump` follows any
individual without interrupting it. Close the group when the swarm lands.

## Organize + clean up

```sh
gctd rename $ID name=server
gctd group $ID1 $ID2 name=feature color=#3b82f6
gctd focus $ID          # focus + center the pane on the canvas
gctd camera $ID zoom=0.5 dur=2   # glide the camera (or x= y=)
gctd do fit-all         # any keybind action by config name
gctd ungroup <group>    # panes survive
gctd close $ID
```
## Rules

- Never `run_in_background` for a command you could `gctd open`. Named
  pane (`name=<task>`), grouped per feature, nearby, sized for the job.
  Tell the user the pane name so they can look.
- `dump --strip-ansi` before claiming a task's output; raw VT lies.
- `send` is keystrokes, not an API: prefer `open cmd=` for one-shot
  commands, `send` for driving interactive programs.
- Clean up after yourself: close task panes (and empty groups) when the
  work lands. Stray terms accumulate — `gctd list` before you finish and
  close what you opened. Long-running servers the user still needs stay,
  named and grouped so they read as intentional.
- Never `gctd stop` — it kills the daemon and every pane.
