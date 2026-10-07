# Grand Central Terminal

A terminal multiplexer that behaves like tmux but lives on an **infinite
canvas**: no splits, no tabs — panes are free-floating windows you place,
move, resize, and zoom around, exactly like a figma/miro board of terminals.

Built on **libghostty** (Ghostty's core) for terminal emulation + GPU
rendering, with a tmux-style **client/daemon split**: a headless daemon owns
every PTY, so closing the app detaches and the shells keep running; relaunch
and everything reattaches, scrollback replayed.

![concept](2.png)

## What's implemented

- Infinite canvas: drag empty space to pan, scroll to zoom (0.03–1.0×,
  native-size text stays crisp), `⌘0` fits all panes.
  - drag the titlebar to move, edges/corners to resize (live PTY reflow)
  - click to focus; `⌘H/J/K/L` moves focus to the nearest pane in that
    direction (camera centers + zooms to fit it — both configurable);
    `⌘P` opens a type-to-filter switcher and jumps the camera the same way
  - `⌘T` new pane (opens beside the focused pane — direction and size are
    configurable — and focuses + centers it; inherits the focused pane's
    cwd), `⌘W` close, `⌘R` rename (the `✻`-style named panes in the
    titlebar). `⌘⇧H/J/K/L` opens a new pane on that fixed side with the
    same size/focus/camera rules
  - panes never overlap unless you allow it: creation, titlebar drags,
    edge/corner resizes, and keyboard grow/shrink all resolve collisions
    (keyboard grow shoves blocking panes out of the way along that axis,
    chained); layouts saved while overlap was allowed are untangled on load
  - `⌘C` copies the selection (or sends `^C` when nothing is selected),
    `⌘V` pastes
  - dead keys, accents, and IME composition work: keys route through the
    text input system, preedit renders inline at the cursor, commit lands
    as typed input, and composition keys (⌫, ^H) only affect the preedit
- Titlebars track the shell's cwd (`local – Terminal – /path`) and honor
  program-set titles + OSC 7 (covers ssh panes).
- Daemon (`gctd`) persists pane layout to
  `~/Library/Application Support/Grand Central Terminal/state.json`; on daemon
  restart it respawns shells in their recorded cwd/rects. Scrollback lives
  with the daemon (8 MiB ring per pane) and is replayed on attach.

## Layout

```
vendor/ghostty/          ghostty @ a4aacd91 + patches/libghostty-external-io.patch
patches/                 the external-IO delta (see patches/README.md)
Sources/Common/          wire protocol + framed unix-socket connection
Sources/Daemon/          gctd: PTYs, panes, scrollback, persistence
Sources/PtyExec/         setsid + TIOCSCTTY + exec helper (per-pane child)
Sources/Canvas/          the AppKit app: camera, panes, switcher, input
scripts/build.sh         builds everything into build/Grand Central Terminal.app
scripts/fetch-ghostty.sh clones + patches the vendored ghostty
```

## Build

```sh
scripts/fetch-ghostty.sh     # once: clone ghostty at the pinned commit + patch
scripts/build.sh             # libghostty (zig 0.16, incremental) + daemon + app
open "build/Grand Central Terminal.app"
```

Prereqs: Xcode (macOS SDK), [zig 0.16.0](https://ziglang.org/download/) on
`PATH` (or `ZIG=/path/to/zig`), Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`, one-time).

`scripts/build.sh` stages the daemon at
`~/Library/Application Support/Grand Central Terminal/bin/gctd`; the app
auto-starts it if it isn't running.

## Daemon

```sh
gctd status     # list panes
gctd stop       # kill daemon + panes
```

Each pane's shell runs via `ptyexec`, which takes a fresh session, claims
the slave pty as its controlling terminal, and execs the shell — without
the ctty, `TIOCSWINSZ` never delivers `SIGWINCH` and tty signals (^C, ^Z,
job control) don't work. The pane environment pins `TERM=xterm-256color`,
`COLORTERM=truecolor`, and `LANG=en_US.UTF-8` (GUI-launched daemons inherit
launchd's sparse env, which degrades htop et al. to monochrome), and strips
`NO_COLOR` (tool harnesses set it; panes are new terminals and should color).

## How the external backend works

Upstream libghostty surfaces always spawn their own PTY. This project needs
the daemon to own the PTYs, so we carry a small delta (ported from
`daiimus/ghostty:ios-external-backend` onto upstream master) that adds a
`GHOSTTY_BACKEND_EXTERNAL` termio backend: the app feeds raw VT bytes in via
`ghostty_surface_write_output` (serialized on a per-surface queue) and
receives keystrokes through the surface's `write_callback`; grid resizes
arrive via `resize_callback` and go to the daemon as `TIOCSWINSZ`. See
`patches/README.md`.

## Known limits (v0.1)

- The daemon's scrollback ring is memory-only: `gctd stop` loses history
  (same as killing a tmux server).
- Remote/ssh panes are not wired into the UI yet — the daemon supports a
  `command` per pane, but the app only spawns local shells.
- Panes render live at every zoom level; many heavy panes will cost GPU.
- macOS quirk: `read()` on a pty master never returns when the shell dies
  (unlike Linux's EIO), so dead panes are detected by the daemon's reaper
  and can linger briefly as a frozen frame before cleanup.

## Keys

| Key | Action |
| --- | --- |
| `⌘T` | new pane |
| `⌘W` | close focused pane |
| `⌘R` | rename focused pane |
| `⌘H/J/K/L` | move focus left/down/up/right |
| `⌘⌃H/J/K/L` | grow focused pane toward left/down/up/right (shoves blockers) |
| `⌘⌃⇧H/J/K/L` | shrink focused pane from that edge |
| `⌘P` | pane switcher (type to filter, ⏎ to jump) |
| `⌘0` | fit all panes |
| scroll | zoom canvas (toward cursor) |
| shift+scroll | scroll the terminal under the cursor |
| drag empty space | pan |
| drag titlebar | move pane |
| drag edges/corners | resize pane |

## Configuration

`~/.config/gct/config.toml` — created with defaults on first launch; every key
is optional and malformed values fall back to their defaults. Takes effect on
relaunch. Root-level keys (like `appearance` and the placement keys below)
must appear before the first `[table]` header — after one, they belong to
that table.

```toml
# Light/dark mode: "light", "dark", or "system" (follow macOS).
appearance = "system"

# Window placement. Panes are kept from overlapping unless you allow it:
# new panes, moves, and resizes all resolve collisions.
allow-window-overlap = false
# Side of the focused pane that cmd+t opens on.
new-window-open-direction = "right"  # above | below | left | right
# New pane size: "follows" copies the focused pane, or fix a terminal grid
# as "cols,rows" (e.g. "80,30"). With no panes on the canvas, a standard
# 80x24 terminal opens. Directional open-new-window-* uses this same size.
new-window-dim = "follows"
# Keyboard resize step (grow-window-*/shrink-window-*): one terminal cell
# per press when measurable, else resize-step-points. resize-step-cells
# scales the cell step (e.g. 2 = two cells per press).
resize-step-cells = 1
resize-step-points = 40
# Animate the camera to center a pane created with cmd+t or an
# open-new-window-* bind (when its focus move fires).
move-focus-on-new-window = true
# Directional focus moves (cmd+h/j/k/l): center the newly focused pane,
# and/or zoom to fit it. Independent; both default true (fit implies
# centered, so both true just zooms to fit).
camera-follows-focus-move = true
camera-fits-focus-move = true

# Canvas background per mode. Hex like "#1a1b26" (alpha 1), or with alpha
# like "#1a1b2680" / "#1234" — alpha < 1 makes the canvas transparent,
# showing the desktop behind it. "ghostty" reuses the background color
# from your ghostty config.
dark = "#000000"
light = "#ffffff"

[titlebar]
# Pane titlebar colors. Hex like "#2b2b2b", or "default" for the usual grey.
background = "default"
text = "default"
# Title text font: family name (e.g. "SF Mono") and size in points.
font = "default"
font-size = 12

[keybinds]
# App shortcuts. Modifiers cmd, ctrl, alt, shift joined with "+"; the last
# part is the key, e.g. new-pane = "cmd+shift+t".
new-pane = "cmd+t"
close-pane = "cmd+w"
rename-pane = "cmd+r"
move-focus-above = "cmd+k"
move-focus-below = "cmd+j"
move-focus-left = "cmd+h"
move-focus-right = "cmd+l"
# Directional new panes. Side is fixed by the action; size follows
# new-window-dim; focus/camera follow move-focus-on-new-window and the
# camera-follows/fits-focus-move flags.
open-new-window-above = "cmd+shift+k"
open-new-window-below = "cmd+shift+j"
open-new-window-left = "cmd+shift+h"
open-new-window-right = "cmd+shift+l"
# Directional resize: grow moves that edge outward (shoving blockers when
# overlap is disallowed), shrink pulls it back. Opposite edge stays put.
grow-window-above = "cmd+ctrl+k"
grow-window-below = "cmd+ctrl+j"
grow-window-left = "cmd+ctrl+h"
grow-window-right = "cmd+ctrl+l"
shrink-window-above = "cmd+ctrl+shift+k"
shrink-window-below = "cmd+ctrl+shift+j"
shrink-window-left = "cmd+ctrl+shift+h"
shrink-window-right = "cmd+ctrl+shift+l"
switcher = "cmd+p"
fit-all = "cmd+0"
copy = "cmd+c"
paste = "cmd+v"
```

Terminal colors (inside panes) are ghostty's domain and come from your ghostty
config as usual; the `background.dark`/`light` value `"ghostty"` makes the
canvas follow whatever background your ghostty config resolves to.
