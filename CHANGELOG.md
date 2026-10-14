# Changelog

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
