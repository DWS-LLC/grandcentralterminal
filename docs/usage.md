# Using the canvas

Shortcuts are in [keybindings.md](keybindings.md); knobs are in
[configuration.md](configuration.md).

## Moving around

Drag empty space to pan. Scroll over a terminal scrolls the terminal (wheel or
trackpad, no modifier); scroll over empty canvas pans (two-finger trackpad) or
zooms toward the cursor (mouse wheel). Pinch zooms too. Zoom runs 0.03-4.0×
by default; above 1.0 the texture magnifies, so use per-pane `⌘+/-` for sharp
big text.

`⌘0` fits all panes. Two-finger double-tap toggles actual size vs fit-all.
`⌘P` opens a type-to-filter switcher and glides the camera to the pick.
`⌘H/J/K/L` focuses the nearest pane in that direction; the camera centers and
zooms to fit it (both configurable).

`⌘Z` focus-zooms a pane into a sharp local fullscreen: the surface reflows and
re-renders vector-crisp, never a raster upscale. A `⤢` marker and accent
chrome show while zoomed. The toggle restores frame and camera; focus moves,
`⌘0`, titlebar/resize grabs, and double-tap exit; pan, wheel, and pinch hold.

## Panes

`⌘T` opens a pane beside the focused one (direction and size configurable),
focuses and centers it. It inherits the focused pane's cwd and `⌘+/-` zoom.
`⌘⇧H/J/K/L` opens on a fixed side instead. `⌘W` closes, `⌘R` renames (the
`✻`-style names in the titlebar; on a grouped pane it renames the group).
Opt-drag on empty space draws a pane of whatever size you drag.

Drag the titlebar to move (the whole band grabs), edges and corners to
resize; the PTY reflows live. Click focuses (`focus-follows-mouse = true`
focuses on hover). Click-drag inside a terminal selects text.

Mouse drags never shove anything aside: they slide along collisions and hold
when wedged. Only keyboard grow shoves (`allow-mouse-drag-to-push = true` opts
mouse drags in).

Dead keys, accents, and IME composition work: keys route through the text
input system, preedit renders inline at the cursor.

## Groups

Groups are a convenience, not a hierarchy. A pane without one is perfectly
normal.

Multi-select first: right-drag empty space to stage a selection, `⇧`-click a
titlebar to toggle one pane, `⌘D` toggles the focused pane, `⌘⇧D` clears.
Drag a selected titlebar to move the block rigidly. `⌘W` closes every selected
pane. `⌘G` groups the selection into a colored box you can drag, rename, and
recolor from its right-click menu. A directional split from a grouped pane
joins that group; loose panes in the way are shoved aside along the split axis
and foreign groups refuse the join. A group with no members left is deleted.

Right-click anywhere off-pane pops one menu: selection actions when live,
group actions on a group background, plus "New pane here".

## Floating

`⌘F` floats a pane over its scope: a grouped pane over its siblings, an
ungrouped one over every other ungrouped pane. It stacks above tiled panes
with a `⬆` marker and deeper shadow. Foreign group bounds still block
floaters, tiled panes slide under floaters instead of shoving them, and `⌘F`
again re-tiles it. With `allow-window-overlap = true` everything already
overlaps, so floating only changes stacking and the marker.

## Persistence

The daemon (`gctd`) persists layout and groups to
`~/Library/Application Support/Grand Central Terminal/state.json`. On daemon
restart it respawns shells in their recorded cwd and rects and restores groups
(members pruned to live panes). Scrollback lives with the daemon (8 MiB ring
per pane) and replays on attach.

`⌘Q` quits the canvas; panes keep running. The Dock menu's "Quit Daemon" kills
every terminal. A Dock click re-summons a doom-hidden window.

```sh
gctd status     # list panes
gctd stop       # kill daemon + panes
```

## Pane environment

Each pane's shell runs via `ptyexec`, which takes a fresh session, claims the
slave pty as its controlling terminal, and execs the shell. Without the ctty,
`TIOCSWINSZ` never delivers `SIGWINCH` and tty signals (^C, ^Z, job control)
don't work. The environment pins `TERM=xterm-256color`, `COLORTERM=truecolor`,
and `LANG=en_US.UTF-8` (GUI-launched daemons inherit launchd's sparse env,
which turns htop monochrome) and strips `NO_COLOR`, because panes are new
terminals and should color.
