#!/usr/bin/env bash
# CI release build for Linux: gctd + ptyexec with a static Swift stdlib,
# so the tarball runs on most distros without a Swift toolchain.
# Runs inside docker.io/library/swift:<ver> (glibc stays dynamic —
# present everywhere; everything Swift is baked in).
#
# Env:
#   VERSION    release version, e.g. 0.3.0 (names the tarball)
#   SWIFT_VER  container tag (default 6.4)
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

ARCH="$(docker run --rm "docker.io/library/swift:${SWIFT_VER}" uname -m)"
OUT="build/gctd-${VERSION}-linux-${ARCH}.tar.gz"
mkdir -p build
# Static Swift stdlib: the only .so needs left are libc/libm/glibc.
docker run --rm -v "$STAGE:/work" -w /work "docker.io/library/swift:${SWIFT_VER}" \
  bash -c 'swift build -c release --static-swift-stdlib 2>&1 | tail -2; echo "BIN_DIR=$(echo .build/*/release)"' \
  | tee /tmp/gct-linux-build.log
BIN_DIR="$(grep -o 'BIN_DIR=[^ ]*' /tmp/gct-linux-build.log | tail -1 | cut -d= -f2)"
tar -czf "$OUT" -C "$STAGE/$BIN_DIR" gctd ptyexec
cp SKILL.md "build/gctd-${VERSION}-SKILL.md"
echo "release: $OUT"
echo "linked libs (must be stock libc only):"
tar -xzf "$OUT" -C "$STAGE"
ldd "$STAGE/gctd"
