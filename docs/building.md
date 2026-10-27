# Building and releasing

Prereqs: Xcode (macOS SDK), [zig 0.17.0](https://ziglang.org/download/) on
`PATH` (or `ZIG=/path/to/zig`), and the Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`, one-time).

```sh
scripts/fetch-ghostty.sh  # once: clone ghostty at the pinned commit + patch
make build                # libghostty (zig, incremental) + app bundle
make install              # sign (Developer ID) + /Applications +
                          # /usr/local/bin/gctd + harness skill install
make uninstall clean      # remove /Applications copy; drop artifacts
```

`SIGN_IDENTITY=` overrides the Developer ID signer. `make build` stages the
daemon at `~/Library/Application Support/Grand Central Terminal/bin/gctd`; the
app auto-starts it if it isn't running.

Don't `make build` while the canvas you're using is live: it overwrites the
running `gctd` in place. `swift build -c release` is safe.

## Layout

```
vendor/ghostty/          ghostty @ a4aacd91 + patches/libghostty-external-io.patch
patches/                 the external-IO delta (see patches/README.md)
Sources/Common/          wire protocol + framed socket connection (unix + TCP)
Sources/Daemon/          gctd: PTYs, panes, scrollback, persistence
Sources/PtyExec/         setsid + TIOCSCTTY + exec helper (per-pane child)
Sources/Canvas/          the AppKit app: camera, panes, switcher, input
Sources/Canvas/HostHub.swift  one conn per daemon, owner routing + id mapping
Makefile                 build/sign/install/uninstall/clean
scripts/                 fetch-ghostty, build-remote, release-{macos,linux}
.forgejo/workflows/      tag v* -> signed macOS + Linux artifacts
demo/                    scripted screenshot kit (see demo/README.md)
docs/media/              README stills
```

```
   ┌──────────────┐  unix socket / TCP   ┌─────────────────────┐
   │ Canvas (app) │ ◄──────────────────► │ gctd                │
   │ libghostty   │   VT bytes, keys,    │ owns PTYs, 8 MiB    │
   │ Metal render │   resize, layout     │ scrollback, state   │
   └──────────────┘                      └──────────┬──────────┘
                                                    │ ptyexec
                                              ┌─────▼─────┐
                                              │ your shell│
                                              └───────────┘
```

## The external backend

Upstream libghostty surfaces always spawn their own PTY. GCT needs the daemon
to own them, so it carries a small delta (ported from
`daiimus/ghostty:ios-external-backend` onto upstream master) that adds a
`GHOSTTY_BACKEND_EXTERNAL` termio backend. The app feeds raw VT bytes in via
`ghostty_surface_write_output` (serialized on a per-surface queue) and
receives keystrokes through the surface's `write_callback`. Grid resizes
arrive via `resize_callback` and go to the daemon as `TIOCSWINSZ`. See
[patches/README.md](../patches/README.md).

## Release

Tag `v*` on main; CI builds both packages and attaches them to the tag's
Forgejo and GitHub release pages.

```sh
git tag v0.3.0 && git push origin v0.3.0
```

- `GrandCentralTerminal-<ver>-macos-arm64.zip`: the `.app` signed with a
  Developer ID (hardened runtime), notarized, ticket stapled. Gatekeeper
  passes offline on a fresh Mac.
- `gctd-<ver>-linux-<arch>.tar.gz`: `gctd` + `ptyexec` with a static Swift
  stdlib (only stock libc stays dynamic). Runs on most distros, no toolchain.

CI secrets: `APPLE_CERT_P12_B64` (base64 Developer ID `.p12`),
`APPLE_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`,
`NOTARY_PASSWORD` (app-specific password), `RELEASE_TOKEN`
(contents:write on the GitHub mirror). Runner labels in
`.forgejo/workflows/release.yml` are `macos-arm64` and `linux`; rename to match
yours.
