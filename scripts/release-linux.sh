#!/usr/bin/env bash
# CI release build for Linux: gctd + ptyexec with a static Swift stdlib,
# so the tarball runs on most distros without a Swift toolchain.
# Toolchain via swiftly (no docker needed); glibc stays dynamic —
# present everywhere; everything Swift is baked in.
#
# Env:
#   VERSION    release version, e.g. 0.3.0 (names the tarball)
#   SWIFT_VER  toolchain version (default 6.4)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:?VERSION required, e.g. VERSION=0.3.0}"
VERSION="${VERSION#v}"  # tags arrive as v0.3.0
SWIFT_VER="${SWIFT_VER:-6.4}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Sources"
cp -r Sources/Common Sources/Daemon Sources/ProcInfo Sources/PtyExec "$STAGE/Sources/"
cat > "$STAGE/Package.swift" <<'EOF'
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GCTRemote",
    targets: [
        .target(name: "ProcInfo", path: "Sources/ProcInfo"),
        .target(name: "Common", path: "Sources/Common"),
        .executableTarget(
            name: "gctd",
            dependencies: ["Common", "ProcInfo"],
            path: "Sources/Daemon"
        ),
        .executableTarget(
            name: "ptyexec",
            path: "Sources/PtyExec"
        ),
    ]
)
EOF

SW_DIR="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}"
if ! command -v swiftly >/dev/null 2>&1; then
  echo "== installing swiftly =="
  curl -fsSL -o /tmp/swiftly.tar.gz \
    https://download.swift.org/swiftly/linux/swiftly-"$(uname -m)".tar.gz
  tar -xzf /tmp/swiftly.tar.gz -C /tmp && rm /tmp/swiftly.tar.gz
  # Fully non-interactive: no prompt, no profile edit, no auto toolchain
  # (the install step below pins SWIFT_VER explicitly).
  /tmp/swiftly init --quiet-shell-followup --no-modify-profile --skip-install
fi
. "$SW_DIR/env.sh"
if ! swiftly list 2>/dev/null | grep -q "$SWIFT_VER"; then
  echo "== installing Swift $SWIFT_VER =="
  swiftly install "$SWIFT_VER" --assume-yes
fi
swiftly use --assume-yes "$SWIFT_VER"
hash -r
swift --version

ARCH="$(uname -m)"
OUT="build/gctd-${VERSION}-linux-${ARCH}.tar.gz"
mkdir -p build
# Static Swift stdlib: the only .so needs left are libc/libm/glibc.
swift build --package-path "$STAGE" -c release --static-swift-stdlib 2>&1 | tail -2
BIN_DIR=$(echo "$STAGE"/.build/*/release)
tar -czf "$OUT" -C "$BIN_DIR" gctd ptyexec
cp SKILL.md "build/gctd-${VERSION}-SKILL.md"
echo "release: $OUT"
echo "linked libs (must be stock libc only):"
tar -xzf "$OUT" -C "$STAGE"
ldd "$STAGE/gctd"
