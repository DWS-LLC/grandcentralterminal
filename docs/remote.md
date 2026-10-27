# Remote daemons

`gctd` runs on macOS (unix socket, `.app`-bundled) and Linux (unix socket plus
optional TCP). The mac canvas talks to any number of remote daemons over TCP.
Each host's windows get their own color, and right-clicking empty canvas offers
"New remote pane" per host.

![Three remote hosts in formation around local panes, each in its own color](media/remote.jpg)

## Install the daemon

Grab `gctd-<ver>-linux-<arch>.tar.gz` from the releases page (static, runs on
any distro), or build and deploy over ssh. Swift builds in a container on the
remote, so you only need ssh and podman there. This installs a systemd user
service (linger on, restart on failure).

```sh
scripts/build-remote.sh user@host 7420 <token>
scripts/install-remote.sh user@host 7420 <token>

# or by hand
gctd --port=7420 --token=<token>
```

## Point the canvas at it

```toml
# ~/.config/gct/config.toml
[host.enterprise]
host = "192.168.1.38"
port = 7420
token = "<token>"
color = "#f59e0b"   # optional; default = hashed onto your ghostty palette
# color-dark / color-light override per mode; "palette:N" works too
```

`⌘⇧R` reloads config; the canvas connects and the host's panes join.

Can't reach the port? Tunnel it (the token never leaves localhost):

```sh
ssh -L 7420:127.0.0.1:7420 -N -f user@host
```

```toml
[host.enterprise]
host = "127.0.0.1"
port = 7420
token = "<token>"
```

Behind a bastion? Set `proxy` and the canvas runs `ssh -W host:port proxy` for
you (key/agent auth only, no prompts; `host` is as the bastion sees it):

```toml
[host.enterprise]
host = "10.0.0.5"
token = "<token>"
proxy = "user@bastion"   # or an ~/.ssh/config alias
```

## Rules

Remote panes behave like local ones: PTYs live on the remote, and scrollback,
resize, groups, and persistence all work. Three exceptions:

- Groups are same-host only. A mixed selection groups its largest same-host
  subset.
- `⌘T` and directional splits follow the focused pane's host.
- Each daemon arbitrates its own layout. The canvas pre-resolves against the
  union world, so cross-host windows never overlap.

`⌘⇧R` reconnects when `[host.*]` changes. A dropped host clears its panes and
is redialed every 60s until it answers (a dead connection is noticed within
~30s). A host that's down is greyed out under "New remote pane", with a
retry button on its row to dial it now.

## CLI against a remote

```sh
gctd --tcp=192.168.1.38:7420 --token=<token> list   # env: GCT_TCP, GCT_TOKEN
gctd --port=7420 --token=<token>                    # serve; env: GCT_PORT, GCT_TOKEN
```

Paths honor `$HOME` first; `GCT_HOME` overrides the base dir (Linux default
`~/.config/gct`).
