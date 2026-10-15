# Changelog

## Unreleased

### Added
- Auto-update from GitHub releases: checks daily and via "Check for Updates…", verifies the Developer ID signature, then replaces the app and restarts the daemon with it (running panes end).

### Fixed
- `gctd open`/`move` respect `window-gap` (the canvas pushes it to the daemon).
- Grouping never refuses for lack of room: loose panes and foreign groups are shoved out of the new border.

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
