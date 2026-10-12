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
    # swiftly's three (libedit/libpython/zip) plus everything the
    # Swift 6.x toolchain links on Debian: without these the final
    # gctd link dies with a bare "Build failed".
    $SUDO apt-get install -y binutils git libc6-dev libcurl4-openssl-dev \
      libedit-dev libpython3-dev libsqlite3-dev libstdc++-12-dev \
      libxml2-dev libz3-dev pkg-config tzdata unzip zip
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
# Fully static via the Static Linux SDK (musl): the binary depends on
# nothing but the Linux syscall interface — runs on any distro, no
# glibc floor, no bundled .so files. --static-swift-stdlib can't do
# this: the toolchain's static ICU shims miss symbols (swift_u*).
# SDK version must match the toolchain (6.4.0 here).
SDK_URL="https://download.swift.org/swift-6.4.0-release/static-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
SDK_SUM="47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e"
if ! swift sdk list 2>/dev/null | grep -q "swift-6.4.0-RELEASE_static-linux"; then
  echo "== installing Static Linux SDK =="
  swift sdk install "$SDK_URL" --checksum "$SDK_SUM"
fi
swift build --package-path "$STAGE" -c release \
  --swift-sdk "${ARCH}-swift-linux-musl" 2>&1 | tee build/linux-build.log | grep -E "error:|Build complete" | head -30
# Pipefail is off for the tee pipe above (grep finds nothing on
# success); fail explicitly when the binaries didn't land.
[ -f "$STAGE"/.build/*/release/gctd ] || { echo "BUILD FAILED — see build/linux-build.log"; exit 1; }
BIN_DIR=$(echo "$STAGE"/.build/*/release)
tar -czf "$OUT" -C "$BIN_DIR" gctd ptyexec
cp SKILL.md "build/gctd-${VERSION}-SKILL.md"
echo "release: $OUT"
echo "linked libs (want: not a dynamic executable):"
file "$BIN_DIR/gctd"
