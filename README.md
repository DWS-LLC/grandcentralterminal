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

- Infinite canvas: drag empty space to pan; scroll over a terminal scrolls
  the terminal (wheel or trackpad, no modifier — `scroll-on-terminal-hover`,
  default true), scroll over empty canvas zooms toward the cursor; pinch
  also zooms (0.03–1.0×, native-size text stays crisp); two-finger
  double-tap toggles actual size vs fit-all; `⌘0` fits all panes.
  - drag the titlebar to move, edges/corners to resize (live PTY reflow)
  - click to focus (`focus-follows-mouse = true` focuses on hover instead);
    click-drag inside a terminal selects text; `⌘H/J/K/L` moves focus to the
    nearest pane in that direction (camera centers + zooms to fit it — both
    configurable); `⌘P` opens a type-to-filter switcher and jumps the
    camera the same way
  - `⌘T` new pane (opens beside the focused pane — direction and size are
    configurable — and focuses + centers it; inherits the focused pane's
    cwd and `cmd-+/-` zoom; a directional split from a grouped pane joins
    that group — loose panes in the way are shoved aside along the split
    axis, cascading, while foreign groups still refuse the join), `⌘W`
    close, `⌘R` rename (the `✻`-style named panes in the titlebar; on a
    grouped pane it renames the GROUP instead).
    `⌘⇧H/J/K/L` opens a new pane on that fixed side with the
    same size/focus/camera rules (joins the focused pane's group too)
    Mouse drags never shove anything aside — they slide along collisions
    and hold when wedged (only keyboard grow shoves;
    `allow-mouse-drag-to-push = true` opts mouse drags back into shoving).
    Multi-select (no grouping until asked): right-drag empty space stages
    a selection, `⇧`-click a titlebar toggles one pane, `⌘D` toggles the
    focused pane, `⌘⇧D` clears; drag a selected titlebar to move the block
    (rigid, slides along collisions), `⌘W` closes every selected pane,
    `⌘G` groups the selection. Right-click anywhere off-pane always pops
    one menu: selection actions when live, group actions on a group
    background, plus "New pane here".
    Floating windows (`⌘F`, `toggle-floating`): a floated pane ignores the
    overlap rule within its own scope — a grouped pane floats over its
    siblings, an ungrouped one over every other ungrouped pane — and
    always stacks above tiled panes with a `⬆` title marker + deeper
    shadow. Foreign group bounds still block floaters, tiled panes slide
    under floaters instead of shoving them, and re-pressing `⌘F` re-tiles
    the pane back into the layout. With `allow-window-overlap = true`
    every window already overlaps, so floating only changes the stacking
    + marker.
  - `⌘C` copies the selection (or sends `^C` when nothing is selected),
    `⌘V` pastes
  - dead keys, accents, and IME composition work: keys route through the
    text input system, preedit renders inline at the cursor, commit lands
    as typed input, and composition keys (⌫, ^H) only affect the preedit
 - Panes carry a titlebar-color border on the left/right/bottom edges
   (`[titlebar] border-width`, default 4pt — wider stays grabbable for
   edge/corner resizes even zoomed out) and a configurable drop shadow
   (`shadow-opacity` 0 turns it off, `shadow-radius` blurs).
- Status bar (`[statusbar]`, off by default): top/bottom overlay of
  xbar-compatible plugin components — any executable in
  `~/.config/gct/statusbar/` named `{name}.{interval}.{ext}`
  (e.g. `clock.10s.sh`), picked up live with no recompile/restart.
  `gap` spacers absorb leftover width, so
  component-gap-component-gap-component aligns left/center/right.
  Click a component for its dropdown menu (`---` section, `--` submenus);
  rows with `href=` open URLs, `shell=` runs detached, `terminal=true`
  opens in a new GCT pane, `refresh=true` re-runs the plugin. Headers
  before the first `---` cycle in the bar; `image=`/`templateImage=`
  take base64 icons. Own background/text color, font, and opacity;
  always above panes on its own layer, outside the camera transform.
- Daemon (`gctd`) persists pane layout + groups to
  `~/Library/Application Support/Grand Central Terminal/state.json`; on daemon
  restart it respawns shells in their recorded cwd/rects and restores groups
  (members pruned to live panes). Scrollback lives
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
| `⌘W` | close focused pane (or every selected pane when focused is selected) |
| `⌘R` | rename focused pane (or its group) |
| `⌘G` | group staged selection (else rename focused pane's group) |
| `⌘D` | toggle focused pane in multi-select |
| `⌘⇧D` | clear multi-select |
| `⌘F` | float / re-tile focused pane |
| `⌘⌃H/J/K/L` | grow focused pane toward left/down/up/right (shoves blockers) |
| `⌘⌃⇧H/J/K/L` | shrink focused pane from that edge |
| `⌘P` | pane switcher (type to filter, ⏎ to jump) |
| `⌘0` | fit all panes |
| scroll over terminal | scroll the terminal (wheel or trackpad) |
| scroll over empty canvas | zoom canvas (toward cursor) |
| click-drag inside terminal | select text (`⌘C` copies) |
| pinch | zoom canvas (toward cursor) |
| two-finger double-tap | toggle actual size / fit all |
| drag empty space | pan |
| right-drag empty space | rubber-band panes into a staged multi-select (no grouping yet) |
| right-click canvas/group background | one menu, always: selection actions (when live) + group actions (on background) + new pane here |
| shift+click titlebar | toggle pane in multi-select |
| drag selected titlebar | move the whole selection as a rigid block |
| drag titlebar | move pane |
| drag group background | move every member together |
| drag edges/corners | resize pane |


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
# Mouse drags never shove anything aside (they slide or hold); keyboard
# grow always shoves. Set true to let mouse drags shove too.
allow-mouse-drag-to-push = false
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
# Focus the pane under the cursor on mouse motion (same name as ghostty's
# focus-follows-mouse). Off by default: click to focus.
focus-follows-mouse = false
# Scroll (wheel or trackpad) over a terminal scrolls the terminal; scroll
# over empty canvas zooms at the cursor. Set false for the old behavior:
# trackpad pans, shift+scroll goes to the terminal, wheel zooms.
scroll-on-terminal-hover = true

# Canvas background per mode. Hex like "#1a1b26" (alpha 1), or with alpha
# like "#1a1b2680" / "#1234" — alpha < 1 makes the canvas transparent,
# showing the desktop behind it. "ghostty" reuses the background color
# from your ghostty config.
dark = "#000000"
light = "#ffffff"

 [titlebar]
 # Pane titlebar colors. RGBA hex like "#2b2b2b" or "#2b2b2bcc", or
 # "default" for the usual grey. The left/right/bottom border uses the
 # same color as the titlebar background.
 background = "default"
 text = "default"
 # Title text font: family name (e.g. "SF Mono") and size in points.
 font = "default"
 font-size = 12
 # Border on the left/right/bottom edges in points (the top edge is the
 # titlebar itself). Wider borders grab edges/corners for resizing more
 # easily, even zoomed out.
 border-width = 4
 # Drop shadow: opacity 0 turns it off, radius blurs it. Defaults match
 # the current look.
 shadow-opacity = 0.55
 shadow-radius = 12

    [statusbar]
    # Overlay bar of xbar-compatible executables in
    # ~/.config/gct/statusbar/ ({name}.{interval}.{ext}, e.g.
    # clock.10s.sh — picked up live, no recompile/restart). Needs a
    # relaunch for these keys.
    enabled = false
    # Bar edge: "top" or "bottom". Always above panes on its own layer.
    position = "bottom"
    # Ordered cells: plugin basenames plus `gap` spacers absorbing
    # leftover width (component-gap-component-gap-component =
    # left/center/right).
    components = "clock, gap"
    height = 26
    spacing = 8
    background = "default"
    text = "default"
    font = "default"
    font-size = 12
    # Overall opacity 0-1.
    opacity = 1

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
# Multi-select (staged, NOT a group): right-drag selects, shift+click a
# titlebar toggles, toggle-pane-selection flips the focused pane;
# drag a selected titlebar moves the block; close-pane closes the block
# when focused is selected; group-selection groups it; right-click with
# a live selection offers group / close / clear.
toggle-pane-selection = "cmd+d"
clear-pane-selection = "cmd+shift+d"
# Groups: group-selection (cmd+g) on a 2+ staged selection makes one
# (colored background, blocks non-members even when overlap is allowed);
# otherwise it renames the focused pane's group. Drag the background to
# move it; right-click it for rename/color/ungroup; rename-pane (cmd+r)
# targets the group when the focused pane has one.
group-selection = "cmd+g"
ungroup = "cmd+shift+g"
```

Terminal settings (inside panes) are ghostty's domain and come from your
ghostty config as usual (`~/.config/ghostty/config`, App Support override,
`config-file` includes included); GCT's built-in defaults only fill keys
your config leaves unset. `cmd-+/-` zoom is per-pane and carries to new
panes (off via ghostty's `window-inherit-font-size = false`).
The `background.dark`/`light` value `"ghostty"` makes the canvas follow
whatever background your ghostty config resolves to.
