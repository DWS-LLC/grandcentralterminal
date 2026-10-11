#!/usr/bin/env bash
# Installs the Linux gctd as a systemd user service on a remote host.
# The unit survives logout (linger) and restarts on failure.
#
# Usage: scripts/install-remote.sh <host> [port] [token]
#   host:  ssh target (must already have ~/gct-remote/bin + lib;
#          see scripts/build-remote.sh)
#   port:  TCP port (default 7420)
#   token: TCP auth token (default: generate + print; the token is
#          the ONLY auth — keep it secret, LAN-only listener)
#
# After: declare it in ~/.config/gct/config.toml and hit reload-config.
set -euo pipefail

HOST="${1:?usage: install-remote.sh <host> [port] [token]}"
PORT="${2:-7420}"
TOKEN="${3:-$(openssl rand -hex 24)}"

ssh "$HOST" "mkdir -p ~/.config/systemd/user && cat > ~/.config/systemd/user/gctd.service <<EOF
[Unit]
Description=Grand Central Terminal daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=LD_LIBRARY_PATH=%h/gct-remote/lib
Environment=GCT_TOKEN=$TOKEN
ExecStart=%h/gct-remote/bin/gctd --port=$PORT
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
loginctl enable-linger 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable --now gctd.service
sleep 1
systemctl --user is-active gctd.service"

echo "gctd active on $HOST :$PORT"
echo "token: $TOKEN"
echo
echo '[host.<name>]'
# Strip user@ for the canvas host field (bare address/hostname).
echo "host = \"${HOST#*@}\""
echo "port = $PORT"
echo "token = \"$TOKEN\""
