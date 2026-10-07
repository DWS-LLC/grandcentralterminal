# tmuxInfiniteCanvas

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
- Panes are real terminals (your `$SHELL`, ghostty rendering):
  - drag the titlebar to move, edges/corners to resize (live PTY reflow)
  - click to focus; `⌘K` opens a type-to-filter switcher and animates the
    camera to the chosen pane
  - `⌘T` new pane (inherits the focused pane's cwd, cascades 40pt),
    `⌘W` close, `⌘R` rename (the `✻`-style named panes in the titlebar)
  - `⌘C` copies the selection (or sends `^C` when nothing is selected),
    `⌘V` pastes
- Titlebars track the shell's cwd (`local – Terminal – /path`) and honor
  program-set titles + OSC 7 (covers ssh panes).
- Daemon (`canvasd`) persists pane layout to
  `~/Library/Application Support/tmuxInfiniteCanvas/state.json`; on daemon
  restart it respawns shells in their recorded cwd/rects. Scrollback lives
  with the daemon (8 MiB ring per pane) and is replayed on attach.

## Layout

```
vendor/ghostty/          ghostty @ a4aacd91 + patches/libghostty-external-io.patch
patches/                 the external-IO delta (see patches/README.md)
Sources/Common/          wire protocol + framed unix-socket connection
Sources/Daemon/          canvasd: PTYs, panes, scrollback, persistence
Sources/PtyExec/         setsid + TIOCSCTTY + exec helper (per-pane child)
Sources/Canvas/          the AppKit app: camera, panes, switcher, input
scripts/build.sh         builds everything into build/Canvas.app
scripts/fetch-ghostty.sh clones + patches the vendored ghostty
```

## Build

```sh
scripts/fetch-ghostty.sh     # once: clone ghostty at the pinned commit + patch
scripts/build.sh             # libghostty (zig 0.16, incremental) + daemon + app
open build/Canvas.app
```

Prereqs: Xcode (macOS SDK), [zig 0.16.0](https://ziglang.org/download/) on
`PATH` (or `ZIG=/path/to/zig`), Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`, one-time).

`scripts/build.sh` stages the daemon at
`~/Library/Application Support/tmuxInfiniteCanvas/bin/canvasd`; the app
auto-starts it if it isn't running.

## Daemon

```sh
canvasd status     # list panes
canvasd stop       # kill daemon + panes
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

- No IME composition (dead keys/accents are limited); everything else types
  fine through ghostty's key encoder.
- The daemon's scrollback ring is memory-only: `canvasd stop` loses history
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
| `⌘K` | pane switcher (type to filter, ⏎ to jump) |
| `⌘0` | fit all panes |
| scroll | zoom canvas (toward cursor) |
| shift+scroll | scroll the terminal under the cursor |
| drag empty space | pan |
| drag titlebar | move pane |
| drag edges/corners | resize pane |
