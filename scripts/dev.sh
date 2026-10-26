#!/usr/bin/env bash
# Runs the working tree as a second canvas beside the installed one (brew
# or make build). Own daemon, socket, state; the live install is untouched.
#
#   scripts/dev.sh        build, launch, clean up on quit
#
#   .build/release/gctd ◀──$D/s──▶ .build/release/GrandCentralTerminal
#            └── state + pid in $D (fresh mktemp dir per run)
#
# Bare binaries, never an .app: a bundled build stages its gctd over the
# live Application Support copy and arms the auto-updater. Config comes
# from scripts/dev-config.toml (Gruvbox Dark chrome, ctrl+alt+space, 64pt
# gaps); export GCT_CONFIG_DIR to use another.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIG="${ZIG:-$HOME/bin/zig}"
LIBGHOSTTY_A="vendor/ghostty/macos/build/ReleaseLocal/libghostty-internal.a"
REL=".build/release"
SOCK_WAIT_STEPS=100   # x 0.05s = 5s for the daemon to bind

# libghostty only when patches/header moved (same rule as build.sh).
if [ ! -f "$LIBGHOSTTY_A" ] || [ -n "$(find patches vendor/ghostty/include/ghostty.h -newer "$LIBGHOSTTY_A" 2>/dev/null | head -1)" ]; then
  echo "== building libghostty =="
  (cd vendor/ghostty && PATH="$(dirname "$ZIG"):$PATH" \
    zig build -Demit-xcframework=true -Dxcframework-target=native \
    -Doptimize=ReleaseFast > /tmp/gbuild.log 2>&1) || {
    grep -m1 -B2 -A8 "error:" /tmp/gbuild.log; exit 1; }
fi
mkdir -p lib Sources/CGhostty
/bin/cp -f "$LIBGHOSTTY_A" lib/libghostty.a
/bin/cp -f vendor/ghostty/include/ghostty.h Sources/CGhostty/ghostty.h

# Release build only: `make build` would overwrite the live gctd.
echo "== swift build =="
swift build -c release

# Short path: unix socket paths cap at 104 bytes.
D=$(mktemp -d /tmp/gctdev.XXXX)
export GCT_SOCK="$D/s" GCT_STATE="$D/state.json" GCT_PID="$D/pid"

# Loud dev config (scripts/dev-config.toml) unless GCT_CONFIG_DIR is set.
if [ -z "${GCT_CONFIG_DIR:-}" ]; then
  export GCT_CONFIG_DIR="$D/config"
  mkdir -p "$GCT_CONFIG_DIR"
  /bin/cp -f scripts/dev-config.toml "$GCT_CONFIG_DIR/config.toml"
fi

# Quit (or ctrl-c) stops the dev daemon and drops its scratch dir.
cleanup() {
  [ -f "$GCT_PID" ] && kill "$(cat "$GCT_PID")" 2>/dev/null || true
  [ -n "$D" ] && [ -d "$D" ] && rm -rf "$D"
}
trap cleanup EXIT

# Daemon first: the canvas otherwise spawns the LIVE gctd from
# Application Support (its spawn path is fixed).
"$REL/gctd" > "$D/gctd.log" 2>&1 &
for _ in $(seq "$SOCK_WAIT_STEPS"); do
  [ -S "$GCT_SOCK" ] && break
  sleep 0.05
done
if [ ! -S "$GCT_SOCK" ]; then
  echo "dev gctd never bound $GCT_SOCK:"; cat "$D/gctd.log"; exit 1
fi

echo "== dev canvas on $GCT_SOCK =="
"$REL/GrandCentralTerminal"
