# Changelog

## Unreleased

### Added
- Cables: a pane is wired to the panes it spawned (`gctd open`, `⌘T`, `⌘⇧H/J/K/L`). Bézier cables whose handles hang on springs (they lag, overshoot, and settle when you move a pane), leave each edge square, and spread along a pane side so strands don't cross. Each cable gets one palette color hashed from its start -> end window names when it first appears; `cable-color` takes a hex or `palette:N` for all. `cables = false` turns them off.
- Cable ties (grabbing a cable is forgiving: 14px reach, measured along the rope, not just its points): strands leaving a pane side are tied into a bundle. Press on a cable and drag across strands to tie them together; drag a tie to slide it along the cable (ties collide and keep their order, and stop where their strands part ways), double-click it to remove.

### Fixed
- A pane's spawn parent never matched a live pane on the canvas, so Relax by Relation ignored the strongest link (spawned by).

## v0.10.0

### Added
- Auto names: panes without a custom name show what runs in them (`gct`, `nvim · gct`, `claude · gct · pip fit`, `gct@feat-x`), shortest-unique across the canvas. Rename to nothing to go back to auto.
- Notifications: OSC 9/777, the bell, and OSC 7501 blocked/done/error from panes you're not looking at post a desktop notification and mark the titlebar with `●`; click focuses the pane. `notifications = false` turns it off.
- `gctd notify <pane> [title=..] <text>`, and `gctd agent-setup install --hooks` now merges Claude `Notification` and `Stop` hooks that use it.
- `dim-inactive` / `dim-delay`: quiet unfocused panes fade; output, blocked status, and notices wake them.
- Relax by Relation (`⌘⇧A`, `relax-layout`): a deterministic spring pass pulls related panes (spawn parent, same repo, same dir, same host) together and pushes strangers apart. Undoable.
- `gctd send` reads stdin when given no text, takes `--paste` (bracketed paste), and understands `\xHH` / `\e` escapes (`\x03` is ^C).

### Changed
- Titlebars abbreviate the home directory to `~`.
- `gctd list` shows auto names.

## v0.9.0

### Added
- `pip-aware` (default true): camera fits and centering land panes in the free strip beside the picture-in-picture window, not under it.
- `focus-move-memory` (default true): cmd+h/j/k/l remember where you came from, so the opposite key goes back, staggered layouts included.
- `[background]` `top-fade` / `top-fade-exponential`: the canvas fades into the menubar.

### Fixed
- Camera fits clear the top fade strip; bottom-bar centering was off.

## v0.8.0

### Added
- `gctd open` orbits the calling pane: spawns land in the free air around it, pulled toward the caller and pushed away from every other pane, instead of wedged against a neighbor.
- `gctd version` (`--version`).

### Changed
- Homebrew installs no longer self-update; the app shows the `brew upgrade` command instead.

### Fixed
- `gctd open` from a grouped pane landed on a sibling when the pane to its right was taken.
- `gctd agent-setup` found no skill when `gctd` ran through the `/usr/local/bin` symlink.

## v0.7.0

### Added
- Every color takes `-dark`/`-light` variants and `palette:N` (your ghostty theme's ANSI color N, so it follows the theme).
- New color keys under `[titlebar]`: `border`, `accent`, `shadow-color`. New `[switcher]` section: `background`, `border`, `text`, `text-active`.
- Group color picker: "Auto", a 2x8 swatch grid (normal | bright ANSI), or a custom color panel.
- `gctd open size=w,h`: size a new pane for the job (world points) and keep the beside-the-caller spot.

### Changed
- Accent, snap guides, host and group colors default to your ghostty palette, hashed from the name so they stay put across launches and machines.
- The agent skill and SessionStart hook now say it plainly: panes, not `run_in_background`; nearby, and sized for the job.
- cmd+shift+z and cmd+hjkl share one fit margin.

## v0.6.0

### Added
- `shader` under `[background]`: a ShaderToy GLSL shader as the canvas, transparency included. ShaderToy uniforms incl. `iMouse`, noise in `iChannel0..3` so pasted shaders work as-is; `shader-fps` and `shader-scale` to keep raymarchers off your GPU's throat. `reload-config` recompiles; a broken shader keeps the last good one.
- Ghostty themes load, light/dark variants included, and follow the system appearance.
- `background-dark`/`background-light` under `[titlebar]`. `"ghostty"` derives titlebar and text colors from the theme.

### Fixed
- A ghostty `theme` no longer gets stomped by GCT's base colors.
- New panes render at the camera's zoom instead of backing scale.
- Zooming a pane while the camera is zoomed no longer reflows at camera scale (half the columns at 2x).

### Docs
- `[background]` gets its own section; it was documented under `[canvas]`.

## v0.5.0

### Added
- Auto-update from GitHub releases: checks daily and via "Check for Updates…", verifies the Developer ID signature, then replaces the app and restarts the daemon with it (running panes end).
- `camera-fits-resize` (default true): the camera zooms to fit a pane after a mouse or keyboard resize.
- `scripts/dev.sh`: run the working tree beside an installed GCT (own daemon, loud dev config).

### Fixed
- Frontend crash when two output chunks in a row ended mid-escape sequence.
- Doubled lines and a cursor one row low after zooming: vector-zoom re-renders no longer reflow the terminal.
- Closing a pane now moves the camera to the newly focused one.
- Pane and group titles stay sharp when zoomed in, and on mixed-DPI displays.
- `gctd open`/`move` respect `window-gap` (the canvas pushes it to the daemon).
- Grouping never refuses for lack of room: loose panes and foreign groups are shoved out of the new border.

### Changed
- Titlebar height scales with `font-size` under `[titlebar]`; group headers match.

## v0.4.0

### Added
- `proxy` key on `[host.<name>]`: reach a remote daemon through an ssh jump host (`ssh -W host:port proxy`).
- MIT license.
- Releases are also published to GitHub (DWS-LLC/grandcentralterminal).

### Fixed
- ctrl+tab and ctrl+return key equivalents now go to the terminal instead of the menu.

### Changed
- README rewritten; config, keybindings, usage, agents, remote and build docs moved to `docs/`. The demo reel is gone.

## v0.3.1

### Fixed
- Skill install failed on zip installs ("skill source not found"): the app now stages `SKILL.md` into Application Support alongside the daemon.

## v0.3.0

### Fixed
- Fresh installs from the release zip booted with no daemon (no windows, no `gctd`): the app only looked in Application Support, which only `make build` populated. The app now stages `gctd`/`ptyexec` from its bundle on launch (cp + rename-swap).

### Added
- "Install gctd Command…" in the app menu (also offered once on first launch): symlinks `/usr/local/bin/gctd` (admin prompt) and installs the agent skill + Claude SessionStart hook.
- Agent skill ships in the bundle.

## v0.2.0

### Added
- Program status (OSC 7501): per-pane status shown right-aligned in each titlebar (working/blocked/done/error + message). Done/error dismiss on keystroke. Demo: `demo/bin/osc7501-demo.sh`.
- Trackpad two-finger pan, wheel zoom on empty canvas; momentum pan coasts through terminals.
- Right-click any chrome for the group membership menu.
- Click-focus camera and camera-zoom-pane.
- Resize/zoom persistence.
- About menu.

### Changed
- Titlebar band always drags; resize only from corners and side/bottom edges.
- `window-gap` applies on `reload-config` and next launch.
- Doom summon lifts above fullscreen apps.
- Vector scaling fixes.

### Fixed
- Claude SessionStart hook died every session: `make build` overwrote the running daemon in place, breaking its code signature (SIGKILL, exit 137). `gctd`/`ptyexec` now staged via cp + rename-swap; hook fails open with a 15s timeout.
- Empty groups: daemon deletes them on prune/update/evict, startup scrubs persisted husks.
- Horizontal pan direction.
- Assorted config fixes.

### Docs
- README: download/install from Forgejo releases.
