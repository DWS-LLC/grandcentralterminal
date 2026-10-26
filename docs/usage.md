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

## Names

A pane you haven't named wears an auto name, so a canvas of shells reads at a
glance:

| running | name |
| --- | --- |
| idle shell | `gct`, or `gct/Canvas` (repo, else the shortest dir that tells it from the others: `a/api`, `b/api`) |
| editor, pager, git UI | `nvim · gct` |
| anything else | `make -j8 · gct` |
| coding agent | `claude · gct · pip fit` (the task is the program's own title) |
| linked git worktree | `gct@feat-x` |

`⌘R` sets a custom name; renaming to nothing hands it back to auto. A
foreground command only counts once it holds for about a second, so an `ls`
doesn't flicker the title. Remote panes are named per host.

## Cables

A pane that spawned another (`gctd open` from it, `⌘T` and `⌘⇧H/J/K/L` from the
focused pane) is wired to it with a cable that blends its two windows' colors
(remote host, else group, else hashed onto your ghostty palette; `cable-color`
paints them all one hex or `palette:N`). Cables are ropes: they sag, swing when you drag a pane, and settle,
leaving each pane edge square. A pane side with several cables spreads them
along the edge in the order that keeps them from crossing, and cables touching
the focused pane sit forward.

Strands leaving one pane side get a **tie** that gathers them into a bundle.
Press on a cable and drag across the strands you want together (a line follows
the mouse); release and they're tied where you crossed. Drag a tie to slide it
along the cable, double-click it to remove it. Empty space still pans. Ties on a
shared cable never pass or overlap each other. Ties last for the session.
`cables = false` turns all of it off.

## Dim and notices

Unfocused panes that have gone quiet fade (`dim-inactive`, `dim-delay`);
output wakes them. Panes that are blocked (OSC 7501) or have a notice never
dim.

A pane that wants you gets a desktop notification and a `●` in its titlebar
until you focus it or type: OSC 9 / OSC 777, the bell, an OSC 7501
`blocked`/`done`/`error`, or `gctd notify`. Clicking the notification focuses
the pane. Nothing fires for the pane you're looking at. `notifications =
false` turns it off.

Dead keys, accents, and IME composition work: keys route through the text
input system, preedit renders inline at the cursor.

## Groups

Groups are a convenience, not a hierarchy. A pane without one is perfectly
normal.

Multi-select first: right-drag empty space to stage a selection, `⇧`-click a
titlebar to toggle one pane, `⌘D` toggles the focused pane, `⌘⇧D` clears.
Drag a selected titlebar to move the block rigidly. `⌘W` closes every selected
pane. `⌘G` groups the selection into a colored box you can drag, rename, and
recolor from its right-click menu: Auto (hashed from the name onto your
ghostty palette), a 2x8 swatch grid of its ANSI colors, or a custom color. A directional split from a grouped pane
joins that group; loose panes in the way are shoved aside along the split axis
and foreign groups refuse the join. A group with no members left is deleted.

Right-click anywhere off-pane pops one menu: selection actions when live,
group actions on a group background, plus "New pane here".

## Relax

Arrange > Relax by Relation (`⌘⇧A`, `relax-layout`) runs a spring pass over
the selection, else the focused group, else everything. Panes pull toward the
ones they belong with, strangers push apart, and groups move as blocks:

- spawned by another pane (`gctd open` from it), strongest
- same git repo
- same directory, or one inside the other
- same remote host

It starts from where panes are and is deterministic: the same canvas relaxes
the same way every time. Nothing is live, and Undo Arrange reverts it.

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
