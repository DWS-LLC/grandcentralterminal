# Changelog

## Unreleased

### Added
- Command groups, StarCraft style: select windows or groups, `⌘⇧1-9` stores them in a slot, `⌘1-9` brings them back: the session switches, they are selected and the camera fits them. A slot holds one session's windows and goes when they are all gone or that session detaches. Config names `command-group-assign-N` / `command-group-recall-N`.
- A session with no windows says which one it is, in the middle of the canvas, with the key that opens a pane.
- Plugins: a folder in `~/.config/gct/plugins/` with an `init.lua` that returns `{ setup = function(opts) end }`, started with the daemon like an autoload script and given its `[plugin.<name>]` table from `config.toml` (`enabled = false` keeps it off). `gctd plugin install owner/repo` (or a git URL, `--ref` for a branch, tag or commit), `list`, `update` and `remove` manage them, and `plugins.lock` pins each commit so another machine gets the same code. See docs/scripting.md.
- Command palette, `⌘⇧P` (`command-palette`): GCT's own actions and every script action with a `title` (`gct.action{name=, title=, description=, category=, keywords=, args=, run=}`), filtered as you type. `args = { count = "integer", note = "string?" }` makes the palette ask for each first. A script's entries go when the script does. Protocol 11; an older daemon just shows none.
- `gctd lua` runs a Lua script against the daemon, in the style of Rex's `rex do`: `gct.pane.*` to open, wait on, dump and arrange panes, `gct.on` handlers for events (`pane_created`, `terminal.child_exited`, `terminal.pwd_changed`, `view_changed`, host links...), `gct.wait`, timers, `gct.exec`, `gct.json`, and Rex's layout builders. The script runs in the `gctd lua` process, never inside the daemon. See docs/scripting.md.
- Scripts in `~/.config/gct/autoload/` start with the daemon, restart when saved, stop when deleted, and retry with backoff when they crash. Logs are in `script-logs/` beside `state.json`.
- Bell, title, notification, focus, progress, clipboard and program-status events reach scripts: the canvas reports what it sees and the daemon relays it to clients that subscribed. Protocol 10; an older app or daemon just sends none.
- `gct.block.call` runs Rex's terminal methods on a pane (`title`, `pwd`, `process`, `size`, `program_status`, `format`, `write`, `reset`, `set_theme`, `list_dir`), and `gct.servers()` / `gct.server(label)` aim the pane calls at one peer.
- Key sequences: `[keybinds]` values can be several keys joined with `>` (`new-pane = "ctrl+b>c"`). A readout at the bottom of the canvas shows the keys typed so far; `escape` cancels, and so does waiting longer than `sequence-timeout` (2s by default).
- `gct.bind`, `gct.unbind`, `gct.mode`, `gct.bindings` and `gct.modes` (Rex's `rex.bind` family): a script binds keys, sequences and modes (`resize/left`, exclusive modes, `client.mode.enter`) to built-in actions, its own actions or functions. They live on the canvas while the script runs and go when it does. A key bound to a function waits for it: return `true` to keep the key, anything else lets it through to the terminal (a quarter second to answer, then the key stays eaten). `gct.client.press("ctrl+b>c")` types keys at the canvas.
- `gctd open --keep-open` leaves a pane (dimmed, ✕) with its scrollback after its program ends, so `gctd dump` can still read it. It goes on `gctd close`, or after `keep-open-ttl` in `config.toml` (default `7d`, `0` = until closed). Kept panes don't survive a daemon restart. Protocol 9.
- `gctd wait <pane> for=10m` (and `open --wait for=10m`) gives up after that long and exits 124.
- `gctd open side=right|left|above|below` picks the edge of the calling pane the new pane lands on, and `size=33%,100%` takes a share of the caller's width and height.
- `gctd font +N|-N|reset [pane]` resizes terminal text on every pane, or one, like `⌘+` / `⌘-`. `gctd session <name>` switches the canvas to `local` or a host, attaching it first if needed. Protocol 8.
- Sessions: one canvas per machine. `local` is this machine's gctd, each `[host.<name>]` is another machine's. Right-click → Session picks one (attaching the host if it isn't yet) and `⌘⇧E` cycles the attached ones. Each session keeps its own panes and camera.
- Attached sessions you aren't looking at stay live and still notify (banner, bell, OSC 9, agent hooks); clicking the banner switches to that session and pane. The Session menu shows each host as attached, reconnecting or not attached, with unread counts, and offers Detach. The window title says how many are attached.
- `gctd font` and `gctd session` from any attached daemon reach the canvas, so they work while a host is on screen.
- New remote pane now puts the pane in your session's layout while the pty runs on the other machine, so remote panes group, tie and arrange with local ones. The pane greys out (`○`) while its host is unreachable and reattaches when it's back.
- `gctd open host=<peer>` opens a pane that runs on a peer. `gctd list` shows peers and the guest panes a daemon hosts.
- `gctd list --json`, `gctd inspect [pane]` and `gctd hosts`: full ids, stable keys, everything the daemon knows about a pane.
- `gctd wait <pane>` and `gctd open --wait` block until the program ends and exit with its status (`128+signal` when killed). Panes that ended recently still answer.
- Exit status says what went wrong: 2 bad command line, 3 target missing or ambiguous (candidates are listed), 4 daemon unreachable.
- Panes accept `pane:<uuid>` and a short id suffix. `gctd help <command>` and `gctd <command> --help` give per-command details.
- Panes get `GCT_BIN_DIR`, the `gctd` matching their daemon, first on `PATH`. Startup files that rewrite `PATH` can bury it; see docs/agents.md.

### Changed
- The `⌘P` pane switcher and `⌘⇧P` palette are redrawn: a search pill (the palette's names the session it acts on), sections, a folder-first path under each pane, key hints along the bottom.
- `⌘P` browses the panes of every attached session, a section each, and a pick in another session switches to it. The session rows are pickable too, and list every configured host: picking one that isn't attached attaches it. Panes are in the order you used them, like alt-tab: the one you were on before is already picked, so `⌘P ⏎` flips back.
- The palette puts GCT's own actions before your scripts' and, inside each category, what you ran last first (kept across launches).
- The palette lists the session on screen's script actions, not every attached daemon's, so a pick runs on the machine you are looking at.
- Nothing dials a `[host.<name>]` until you attach it, and attachments don't survive a relaunch. Hosts in `config.toml` are only available. A dropped attached host redials every 60s until you detach it.
- `gctd open` no longer orbits the calling pane: spawns land flush beside it and keep `window-gap` air, like any other placement. The cable to the caller stays.
- `⌘⇧A` spaces panes by exactly `window-gap`. The tree used to keep at least 48 points and stretch parent-to-children gaps up to 640.
- `gctd agent-setup` is now `gctd agent`: `setup`, `status`, `remove`, `show`, `context`. Setup finds agents (Claude Code, Codex, opencode, pi), is safe to rerun, and takes `--agent`, `--project`, `--dry-run`, `--force` and `--json`. It always installs every hook the agent supports, including Claude's `Notification` and `Stop`, and `remove` takes them back out.
- The installed skill is a stub that runs `gctd agent show`, so upgrading gctd updates what agents know. Setup moves Codex to `~/.agents/skills` and sweeps the old per-agent copies (Codex, opencode, Cursor); Cursor is no longer targeted.
- The SessionStart hook prints one line, which pane the agent is in, and nothing outside a GCT pane. It used to list every pane and group.
- Protocol 7: `paneExit` carries the real exit status (it was always 0).
- Protocol 6. The daemon, not the canvas, dials `[host.*]` (it re-reads `config.toml` when it changes). The canvas connects to one daemon at a time. Groups and ties may now mix hosts.
- On macOS the canvas starts the daemon as its own background app (`GCT Daemon.app`) instead of as its child, so the daemon's LAN links to peers survive the canvas quitting. Its stderr goes to `daemon.log` beside `state.json`.
- A peer's guest panes live outside its own layout: attaching to that machine's session never shows them, and a peer you stop talking to loses them after 7 days (or at the next reconnect, if you no longer have a pane for them).

## v0.14.0

### Added
- Links: hovering one shows the hand cursor and its URL bottom-left of the pane; `⌘`-click opens it (URLs in the browser, bare paths in their default app). Works on unfocused panes too.

### Changed
- Protocol 5: `gctd open` and `gctd group` match replies by request id. Older daemons keep working.

### Fixed
- Closing a pane hangs up its shell (SIGHUP, then SIGKILL) instead of leaving it behind.
- A wedged program can't stall the daemon: input drains on its own thread, attach replays outside the lock.
- The canvas retries the local daemon until it answers; remote hosts dial off the main thread with a 10s handshake cap, so a dead host doesn't freeze the UI.
- State is saved on quit, SIGTERM and SIGINT; saves are ordered and capped at one per second.
- TCP clients get nothing until they've sent the token.
- `gctd send '\xHH'` sends the raw byte; `gctd dump` trims cut UTF-8 instead of falling back to base64.
- CLI rejects non-finite numbers, empty ids and ambiguous id prefixes.
- Status bar plugins don't hang on full or grandchild-held pipes.
- Notify hooks no longer duplicate or keep stale `gctd` paths.
- Updater only accepts well-formed release tags.

## v0.13.0

### Added
- Cables are ropes: they hang under gravity, drape over panes, catch on corners and rest against sides instead of cutting through. Each runs off a reel at its windows and ties that winds it in to `cable-slack` (default 0.06) past a straight line, so there's no spare rope to loop. Pushed hard into a pane, a rope passes through it until it's clear.
- Pane right-click: Rename… and Use auto name.

### Changed
- Arrange By has Relation (the cable tree, the default) alongside the sort keys, replacing the separate Relax by Relation item. Picking Rows / Columns / Grid from Relation sorts by the last key (Name at first).
- `⌘⇧A` relaxes the whole canvas, whatever is focused. The Arrange menu still narrows to the selection or the focused group.
- Holding a key repeats it (vim `hjkl`) instead of opening the accent picker. `defaults write <bundle> ApplePressAndHoldEnabled -bool true` brings the picker back.

### Fixed
- Ties saved by earlier versions come back where they were drawn.

## v0.12.0

### Added
- Clipboard access from programs in a pane: OSC 52 and kitty's OSC 5522 read and write the macOS pasteboard, with a confirm sheet before anything is read or written.

### Changed
- Ghostty 1.4.0 (zig 0.17) under the hood.
- Paste goes through Ghostty's own paste path, so bracketed paste and unsafe-paste protection apply.

## v0.11.1

### Added
- Remote hosts that drop or aren't up at launch are redialed every 60s, so updating a remote daemon no longer needs a config reload. "New remote pane" shows a retry button on the row of a host that's down.

### Changed
- Relax by Relation glides panes to their new spots (over `camera-animation-duration`) instead of jumping, and holds the focused pane where it is: the rest of the layout moves around it.
- Resizing a pane with the mouse no longer zooms the camera to fit it. `camera-fits-resize` covers keyboard resizes only.

### Fixed
- Dead remote connections (sleep, wifi flip, killed daemon) are noticed in ~30s via TCP keepalive. Before, the host looked connected forever and creating a remote pane did nothing.

## v0.11.0

### Added
- Cables: a pane is wired to the panes it spawned (`gctd open`, `⌘T`, `⌘⇧H/J/K/L`). Bézier cables whose handles hang on springs (they lag, overshoot, and settle when you move a pane), leave each edge square on the side facing the other pane, and sit where the cable comes out straightest (level with the other pane when they overlap, else as near as the edge allows), spread apart so strands don't cross, never within 15% of a corner. Strands of one of your ties that share a pane leave it together, on the side facing the whole tie, and meet each other pane on the opposite side. Each cable gets one palette color hashed from its start -> end window names when it first appears; `cable-color` takes a hex or `palette:N` for all. `cables = false` turns them off.
- Cable ties (grabbing a cable is forgiving: 14px reach, measured along the rope, not just its points): strands leaving a pane side are tied into a bundle. Press on a cable and drag across strands to tie them together; a stroke needs two or more strands, and always lands (near the ends it slides to the closest free spot); drag a tie to slide it smoothly along the cable (ties collide and keep their order); a tie is a waypoint the strands pass through side by side, drawn as smooth curves, so it works on strands from anywhere, however far apart, with no humps; a strand that would have to loop back through a tie isn't held by it; which way a bundle flows comes from how its ports face, so a wide fan of children still ties), double-click it to remove.

- `gctd open parent=<pane>` wires a new pane to any pane, not just the caller; `gctd tie <parent> <child>...` and `gctd untie` manage cable ties from scripts. Ties (yours and scripted) are kept by the daemon: they survive restarts and show on every canvas. Protocol 4 (older daemons keep working; their ties stay canvas-local).

### Changed
- Relax by Relation (`⌘⇧A`) uses only the cables as the relation (spawned by) and lays them out as a left-to-right tree: a pane right of the pane that spawned it, siblings in a column with room for their ties, a parent centered on its children, unrelated panes in rows. Replaces the spring pass; same repo, dir and host no longer pull panes together.

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
