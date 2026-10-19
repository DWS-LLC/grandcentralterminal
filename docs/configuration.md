# Configuration

`~/.config/gct/config.toml`, created with defaults on first launch. Every key
is optional; malformed values fall back to their defaults. `⌘⇧R`
(`reload-config`) re-reads it live: theme, keybinds, snapping/overlap policy,
status bar, doom hotkey. Only doom's structural keys (`enabled`,
`start-hidden`, `launch-at-login`) need a relaunch.

Root-level keys (like `appearance` and the placement keys below) must appear
before the first `[table]` header. After one, they belong to that table.

Keybinds live in [keybindings.md](keybindings.md).

## Terminal settings

Settings inside panes are ghostty's domain. They come from your ghostty
config as usual (`~/.config/ghostty/config`, App Support override,
`config-file` includes included); GCT's built-in defaults only fill keys your
config leaves unset. `cmd-+/-` zoom is per-pane and carries to new panes (off
via ghostty's `window-inherit-font-size = false`). `dark = "ghostty"` (below)
makes the canvas follow whatever background your ghostty config resolves to.

## Root keys

```toml
# "light", "dark", or "system" (follow macOS).
appearance = "system"

# Window placement. Panes are kept from overlapping unless you allow it:
# new panes, moves, and resizes all resolve collisions.
allow-window-overlap = false
# Forced padding between windows in world points (0-256, default 0 = flush).
# Raising it re-spreads existing panes on reload-config (and next launch);
# lowering it only affects future moves.
window-gap = 0

# Magnetic snapping: drags/resizes within snap-radius pull flush with nearby
# panes and light full-canvas guides. snapping-type picks the anchors: edges
# (min/max), center (mid), or all. Grouped panes (even solo) snap only to
# siblings; whole-group drags snap the group border to ungrouped panes and
# foreign group borders; ungrouped panes snap to ungrouped panes and group
# borders, never into grouped members.
snapping = true
snapping-type = "edges"  # edges | center | all
snap-radius = 16         # screen points, constant feel at any zoom
show-snap-guides = true
# hex like "#ff453a", "default" for translucent silver, "none" to hide
# (the snap still applies).
snap-guide-color = "default"

# Mouse drags slide along collisions or hold when wedged; keyboard grow
# always shoves. true lets mouse drags shove too.
allow-mouse-drag-to-push = false

new-window-open-direction = "right"  # above | below | left | right
# New pane size: "follows" copies the focused pane, or fix a grid as
# "cols,rows" (e.g. "80,30"). With no panes, a standard 80x24 opens.
# Directional open-new-window-* uses this too.
new-window-dim = "follows"

# Keyboard resize step: one terminal cell per press when measurable, else
# resize-step-points. resize-step-cells scales the cell step.
resize-step-cells = 1
resize-step-points = 40

# Animate the camera to center a pane created with cmd+t or an
# open-new-window-* bind.
move-focus-on-new-window = true
# Directional focus moves (cmd+h/j/k/l): center the new pane and/or zoom to
# fit it. Independent; both true just zooms to fit.
camera-follows-focus-move = true
camera-fits-focus-move = true
# Zoom to fit a pane after resizing it (mouse or keyboard).
camera-fits-resize = true

# Focus the pane under the cursor on mouse motion (ghostty's name for it).
focus-follows-mouse = false
# Scroll over a terminal scrolls the terminal; over empty canvas it zooms at
# the cursor. false: trackpad pans, shift+scroll goes to the terminal,
# wheel zooms.
scroll-on-terminal-hover = true

# Canvas zoom limits for wheel/pinch (1.0 = actual size). Above 1.0 the
# terminal texture magnifies (slightly soft); per-pane cmd-+/- stays sharp.
zoom-min = 0.03   # 0.005-1
zoom-max = 4      # 1-8
# Camera glide in seconds (focus moves, fit-all, switcher), 0.05-10.
camera-animation-duration = 0.28
```

## `[background]`

```toml
[background]
# Canvas background per mode. Hex like "#1a1b26", or with alpha like
# "#1a1b2680". Alpha < 1 makes the canvas transparent, showing the desktop.
# Transparent canvas is look-but-don't-touch: empty space stops receiving
# mouse events (no pan, no opt-drag); panes keep working.
# "ghostty" reuses the background from your ghostty config.
dark = "#000000"
light = "#ffffff"
# ShaderToy GLSL drawn as the canvas instead. Path, ~ or relative to the
# config dir. The color's alpha scales the shader's.
shader = "shaders/background.glsl"
shader-fps = 60  # 1-120
shader-scale = 1 # render resolution vs native, 0.1-1
```

The shader is a ShaderToy `mainImage` with `iTime`, `iTimeDelta`,
`iFrame`, `iFrameRate`, `iResolution`, `iMouse` (ShaderToy rules: tracks
while the left button is down), `iDate`, `iChannelTime`, `iChannelResolution`. `iChannel0..3` are a
256x256 RGBA noise texture laid out like ShaderToy's "RGBA Noise Medium"
(R is G offset by (37, 239)), so noise shaders work as pasted. Raymarchers
are expensive at Retina sizes: `shader-scale = 0.5` costs a quarter of the
GPU, and `shader-fps = 30` halves that again. It's screen space: panes pan over it. Unlike ShaderToy, alpha is
real, so write `1.0` unless you want the desktop through. `reload-config`
recompiles an edited shader; a broken one logs to Console and the last good
one keeps drawing.

## `[titlebar]`

```toml
[titlebar]
# RGBA hex like "#2b2b2b" or "#2b2b2bcc", or "default" for the usual grey.
# The left/right/bottom border uses the titlebar background.
background = "default"
background-dark = "default"   # per-mode overrides of `background`
background-light = "default"
# "ghostty": derive from your ghostty theme (window-titlebar-background,
# else its background nudged toward the foreground). Text follows.
text = "default"
font = "default"        # family name, e.g. "SF Mono"
font-size = 12
# Border on the left/right/bottom edges in points. Wider is easier to grab
# for resizing, even zoomed out.
border-width = 4
shadow-opacity = 0.55   # 0 turns it off
shadow-radius = 12
```

Programs speaking [OSC 7501 program status](https://www.superlogical.com/rex/docs/build/program-status)
show their state right-aligned in the titlebar: `◌ 40%` working, `▲` blocked,
`✓` done, `✕` error, plus the program's message. Per pane, local and remote,
cleared when you type into the pane.

## `[statusbar]`

Overlay bar of xbar-compatible plugins. Any executable in
`~/.config/gct/statusbar/` named `{name}.{interval}.{ext}` (e.g.
`clock.10s.sh`) is picked up live, no restart.

```toml
[statusbar]
enabled = false
position = "bottom"          # top | bottom
# Ordered cells: plugin basenames plus `gap` spacers that absorb leftover
# width. component-gap-component-gap-component = left/center/right.
components = "clock, gap"
height = 26
spacing = 8
background = "default"
text = "default"
font = "default"
font-size = 12
opacity = 1                  # 0-1
```

Click a component for its dropdown (`---` section, `--` submenus). Rows with
`href=` open URLs, `shell=` runs detached, `terminal=true` opens a new GCT
pane, `refresh=true` re-runs the plugin. Headers before the first `---`
cycle in the bar. `image=` / `templateImage=` take base64 icons. The bar sits
on its own layer above panes, outside the camera transform.

## `[doom]`

Quake-style dropdown. A system-wide hotkey (Carbon, no Accessibility
permission) summons the fullscreen canvas; the same hotkey hides it and
restores the previous app. PTYs keep running while hidden. Panning never
dismisses it.

```toml
[doom]
enabled = true
toggle = "ctrl+space"    # global; named keys work (space, f1-f12...)
animation = "fade"       # fade | slide
animation-duration = 0.2
screen = "mouse"         # mouse | main | menubar
start-hidden = true      # launch ordered-out; hotkey summons
launch-at-login = false  # login item (also in system Settings)
```

The combo is eaten system-wide while GCT runs (shells never see it). Stock
macOS binds `ctrl+space` to input-source switching, so free it in Settings or
pick another bind. The summon lifts the window above fullscreen apps, same
recipe as Ghostty's quick terminal. Registration failure is loud (log + stay
visible) rather than stranding a hidden window.

## `[host.<name>]`

Remote daemons. See [remote.md](remote.md).

## `[keybinds]`

See [keybindings.md](keybindings.md).
