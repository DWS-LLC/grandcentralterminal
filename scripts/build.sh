#!/usr/bin/env bash
# Builds everything: libghostty (patched), gctd, Grand Central Terminal.app.
#
# Prereqs (first run only):
#   - zig 0.16.0 on PATH (or ZIG env var)
#   - Metal Toolchain: xcodebuild -downloadComponent MetalToolchain
#   - Xcode with macOS SDK
set -euo pipefail
cd "$(dirname "$0")/.."

ZIG="${ZIG:-/tmp/zig0160/zig}"
LIBGHOSTTY_A="vendor/ghostty/macos/build/ReleaseLocal/libghostty-internal.a"
SUPPORT="$HOME/Library/Application Support/Grand Central Terminal"

# 1. libghostty (zig build is incremental; cached after first run)
if [ ! -f "$LIBGHOSTTY_A" ] || [ -n "$(find patches vendor/ghostty/include/ghostty.h -newer "$LIBGHOSTTY_A" 2>/dev/null | head -1)" ]; then
  echo "== building libghostty =="
  (cd vendor/ghostty && PATH="$(dirname "$ZIG"):$PATH" \
    zig build -Demit-xcframework=true -Dxcframework-target=native \
    -Doptimize=ReleaseFast > /tmp/gbuild.log 2>&1) || {
    grep -m1 -B2 -A8 "error:" /tmp/gbuild.log; exit 1; }
fi

# 2. stage the static lib + header for SwiftPM linking
mkdir -p lib Sources/CGhostty
cp "$LIBGHOSTTY_A" lib/libghostty.a
cp vendor/ghostty/include/ghostty.h Sources/CGhostty/ghostty.h

# 3. Swift
echo "== swift build =="
swift build -c release
BIN=".build/release"

# 4. App bundle
APP="build/Grand Central Terminal.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/GrandCentralTerminal" "$APP/Contents/MacOS/"
cp "$BIN/gctd" "$APP/Contents/MacOS/"
cp "$BIN/ptyexec" "$APP/Contents/MacOS/"
echo "built $APP"

# 5. Stage daemon where the app expects it.
mkdir -p "$SUPPORT/bin"
cp "$BIN/gctd" "$SUPPORT/bin/gctd"
cp "$BIN/ptyexec" "$SUPPORT/bin/ptyexec"
echo "ready: $APP (daemon staged in $SUPPORT/bin)"
