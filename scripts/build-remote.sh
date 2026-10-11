#!/usr/bin/env bash
# Builds the Linux gctd + ptyexec on a remote host via a Swift container,
# then deploys them to ~/gct-remote/bin (+ Swift runtime in ~/gct-remote/lib).
#
# Usage: scripts/build-remote.sh <host> [port] [token]
#   host:  ssh target (e.g. dubey@192.168.1.38)
#   port:  TCP port the daemon will listen on (default 7420)
#   token: TCP auth token (default: prompts; empty = open listener)
#
# The daemon runs with: LD_LIBRARY_PATH=~/gct-remote/lib \
#   ~/gct-remote/bin/gctd --port=<port> --token=<token>
# State defaults to ~/.config/gct (GCT_HOME/GCT_STATE/GCT_PID override).
#
# Prereqs on the remote: podman, ssh access. No Swift toolchain needed
# locally — the build happens inside docker.io/library/swift:6.4.
set -euo pipefail

HOST="${1:?usage: build-remote.sh <host> [port] [token]}"
PORT="${2:-7420}"
TOKEN="${3:-}"

cd "$(dirname "$0")/.."
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

echo "== syncing sources to $HOST =="
ssh "$HOST" 'mkdir -p ~/gct-remote/build'
scp -rq "$STAGE/Sources" "$STAGE/Package.swift" "$HOST:~/gct-remote/build-tmp" 2>/dev/null || {
    # scp fallback: tar pipe (mixed scp/sftp servers)
    tar -cf - -C "$STAGE" Sources Package.swift | ssh "$HOST" 'rm -rf ~/gct-remote/build-tmp && mkdir -p ~/gct-remote/build-tmp && tar -xf - -C ~/gct-remote/build-tmp'
}
ssh "$HOST" 'rm -rf ~/gct-remote/build && mv ~/gct-remote/build-tmp ~/gct-remote/build'

echo "== building (Swift 6.4 container) =="
ssh "$HOST" 'cd ~/gct-remote/build && podman run --rm -v .:/work -w /work docker.io/library/swift:6.4 swift build -c release 2>&1 | tail -2'

echo "== deploying ~/gct-remote/bin + lib =="
ssh "$HOST" 'mkdir -p ~/gct-remote/bin ~/gct-remote/lib
  cp ~/gct-remote/build/.build/out/Products/Release-linux-*/gctd ~/gct-remote/build/.build/out/Products/Release-linux-*/ptyexec ~/gct-remote/bin/
  chmod +x ~/gct-remote/bin/gctd ~/gct-remote/bin/ptyexec'
# Swift runtime libs (dynamic link): extract once from the container.
ssh "$HOST" 'podman run --rm -v ~/gct-remote/lib:/out docker.io/library/swift:6.4 bash -c "cp /usr/lib/swift/linux/*.so* /out/ 2>/dev/null; ls /out/*.so | wc -l"'

echo "ready on $HOST:"
echo "  LD_LIBRARY_PATH=\$HOME/gct-remote/lib \$HOME/gct-remote/bin/gctd --port=$PORT --token=$TOKEN"
echo "  canvas: [host.<name>] host=\"127.0.0.1\" port=$PORT token=\"$TOKEN\""
echo "  (tunnel: ssh -L $PORT:127.0.0.1:$PORT -N -f $HOST)"
