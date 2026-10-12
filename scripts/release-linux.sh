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
# Already bootstrapped on a previous run (persistent runner home)?
[ -f "$SW_DIR/env.sh" ] && . "$SW_DIR/env.sh"
if ! command -v swiftly >/dev/null 2>&1; then
  echo "== installing swiftly =="
  curl -fsSL -o /tmp/swiftly.tar.gz \
    https://download.swift.org/swiftly/linux/swiftly-"$(uname -m)".tar.gz
  tar -xzf /tmp/swiftly.tar.gz -C /tmp && rm /tmp/swiftly.tar.gz
  # Fully non-interactive: --assume-yes answers Proceed, no profile
  # edit, no auto toolchain (the install step pins SWIFT_VER). NOTE:
  # no `yes |` pipe — pipefail turns yes's SIGPIPE death into a 141.
  /tmp/swiftly init --assume-yes --quiet-shell-followup --no-modify-profile --skip-install
  . "$SW_DIR/env.sh"
fi
if ! swiftly list 2>/dev/null | grep -q "$SWIFT_VER"; then
  # swiftly exits 1 (fatal under set -e) when these are missing, even
  # after a successful toolchain install — so they go in first.
  echo "== installing Swift system deps =="
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO=sudo
  else
    SUDO=
  fi
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update
    $SUDO apt-get install -y libedit-dev libpython3-dev zip
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y libedit python3-devel zip
  elif command -v apk >/dev/null 2>&1; then
    $SUDO apk add libedit-dev python3-dev zip
  fi
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
