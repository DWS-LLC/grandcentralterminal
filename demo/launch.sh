#!/bin/zsh
# Demo canvas beside the live one: own daemon, socket, state, config,
# ghostty theme, and shell history. The live canvas is never touched.
#
#   demo/launch.sh <rice> [glass]   (re)start the app in a rice; panes survive
#   demo/launch.sh reset            kill the demo daemon + wipe its state
#   demo/launch.sh stop             quit the demo app (daemon keeps panes)
#   demo/launch.sh swap <rice>      re-render config only (then reload-config)
#
#   repo build (.build/release) ──copy──▶ $DEMO_HOME/bin + app bundle
#   rices/<rice>.env ──render──▶ config/config.toml + xdg/ghostty/config.ghostty
#   gctd (GCT_SOCK/STATE/PID) ◀──socket── demo app (GCT_SOCK/CONFIG_DIR, XDG)
set -euo pipefail

REPO=${0:A:h:h}
DEMO=${0:A:h}
DEMO_HOME="$HOME/Library/Application Support/GCT Demo"
APP="$DEMO_HOME/Grand Central Terminal.app"
EXE="$APP/Contents/MacOS/GrandCentralTerminal"
LIVE_PLUGINS="$HOME/.config/gct/statusbar"
BTOP_THEMES=/opt/homebrew/share/btop/themes
GHOSTTY_THEMES=/Applications/Ghostty.app/Contents/Resources/ghostty/themes
PLUGINS=(clock.10s.sh cpu.5s.sh mem.10s.sh net.10s.sh gctpanes.5s.sh uptime.1m.sh)

export GCT_SOCK="$DEMO_HOME/daemon.sock"
export GCT_STATE="$DEMO_HOME/state.json"
export GCT_PID="$DEMO_HOME/daemon.pid"

# Demo app processes only (the live app runs from /Applications).
stop_app() {
    pkill -f "$EXE" 2>/dev/null || true
    sleep 0.5
}

# Copy + rename: a running binary keeps its old inode instead of being
# rewritten in place (which gets it SIGKILLed on the next page-in).
put() {
    cp "$1" "$2.tmp"
    mv -f "$2.tmp" "$2"
}

# Fresh binaries every launch: the demo always runs the working tree.
stage_bins() {
    local rel="$REPO/.build/release"
    mkdir -p "$DEMO_HOME/bin" "$APP/Contents/MacOS" "$APP/Contents/Resources"
    for b in gctd ptyexec; do
        put "$rel/$b" "$DEMO_HOME/bin/$b"
    done
    for b in GrandCentralTerminal gctd ptyexec; do
        put "$rel/$b" "$APP/Contents/MacOS/$b"
    done
    cp "$REPO/Resources/Info.plist" "$APP/Contents/Info.plist"
    cp "$REPO/Resources/AppIcon.icns" "$APP/Contents/Resources/"
}

# Clean shells: user's zsh config, but an empty demo-only history so
# autosuggestions never surface real commands on camera.
stage_zsh() {
    local z="$DEMO_HOME/zdot"
    mkdir -p "$z"
    # PATH in .zshenv: `gctd open cmd=` shells are non-interactive.
    print -r -- '[[ -f ~/.zshenv ]] && source ~/.zshenv' > "$z/.zshenv"
    print -r -- "export PATH=\"$DEMO_HOME/bin:$DEMO/bin:\$PATH\"" >> "$z/.zshenv"
    # antidote resolves its bundle relative to ZDOTDIR.
    ln -sf ~/.zsh_plugins.txt ~/.zsh_plugins.zsh "$z/"
    print -r -- '[[ -f ~/.zprofile ]] && source ~/.zprofile' > "$z/.zprofile"
    # Again after /etc/zprofile: path_helper hoists /usr/local/bin (the live
    # gctd) above the demo bin in login shells.
    print -r -- "export PATH=\"$DEMO_HOME/bin:$DEMO/bin:\$PATH\"" >> "$z/.zprofile"
    cat > "$z/.zshrc" <<EOF
source ~/.zshrc
HISTFILE="$DEMO_HOME/zsh_history"
fc -p "$DEMO_HOME/zsh_history"
unsetopt PROMPT_SP
export PATH="$DEMO_HOME/bin:$DEMO/bin:\$PATH"
EOF
}

# rices/<rice>.env + config.toml.in -> config dir; theme -> ghostty conf.
stage_rice() {
    local rice=$1 glass=$2
    local env="$DEMO/rices/$rice.env"
    [[ -f $env ]] || { print -u2 "no rice $rice (have: ${(j:, :)${(@f)$(ls $DEMO/rices | sed 's/\.env$//')}})"; exit 2; }
    source "$env"

    # Glass: translucent canvas + panes over the wallpaper (stills only:
    # a transparent canvas stops taking empty-space mouse input).
    local canvas=$CANVAS opacity=1
    if [[ $glass == glass ]]; then
        canvas=$CANVAS_GLASS
        opacity=$PANE_OPACITY
    fi

    local cfg="$DEMO_HOME/config"
    mkdir -p "$cfg/statusbar"
    # Copies: the plugin scan only takes regular files, not symlinks.
    for p in $PLUGINS; do
        rm -f "$cfg/statusbar/$p"
        cp "$LIVE_PLUGINS/$p" "$cfg/statusbar/$p"
    done
    sed -e "s|@CANVAS@|$canvas|g" -e "s|@TITLE_BG@|$TITLE_BG|g" \
        -e "s|@TITLE_FG@|$TITLE_FG|g" -e "s|@ACCENT@|$ACCENT|g" \
        -e "s|@BAR_BG@|$BAR_BG|g" -e "s|@BAR_FG@|$BAR_FG|g" \
        "$DEMO/config.toml.in" > "$cfg/config.toml"

    # Palette inlined: embedded libghostty can't resolve `theme = <name>`.
    mkdir -p "$DEMO_HOME/xdg/ghostty"
    local conf="$DEMO_HOME/xdg/ghostty/config.ghostty"
    cp "$GHOSTTY_THEMES/$THEME" "$conf"
    # btop (via demo/bin/dbtop): rice theme, no process list on camera.
    mkdir -p "$DEMO_HOME/xdg/btop"
    cat > "$DEMO_HOME/xdg/btop/btop.conf" <<EOF
color_theme = "$BTOP_THEMES/$BTOP_THEME.theme"
theme_background = False
truecolor = True
rounded_corners = True
graph_symbol = "braille"
shown_boxes = "cpu mem net"
update_ms = 500
EOF

    cat >> "$conf" <<EOF
font-family = "JetBrainsMono Nerd Font Mono"
font-size = 15
window-padding-x = 12
window-padding-y = 10
background-opacity = $opacity
cursor-style = bar
EOF
}

# Scrubbed env: nothing from the calling session (agent vars, pane ids,
# NO_COLOR) leaks into on-camera shells.
clean_env() {
    env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL="${SHELL:-/bin/zsh}" \
        TMPDIR="$TMPDIR" LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        GCT_SOCK="$GCT_SOCK" GCT_STATE="$GCT_STATE" GCT_PID="$GCT_PID" "$@"
}

# Daemon outlives app restarts so rice swaps keep the scene.
start_daemon() {
    "$DEMO_HOME/bin/gctd" status >/dev/null 2>&1 && return
    clean_env ZDOTDIR="$DEMO_HOME/zdot" nohup "$DEMO_HOME/bin/gctd" \
        >"$DEMO_HOME/daemon.log" 2>&1 &!
    for _ in {1..50}; do
        [[ -S $GCT_SOCK ]] && return
        sleep 0.1
    done
    print -u2 "demo daemon failed to bind; see $DEMO_HOME/daemon.log"
    exit 1
}

start_app() {
    clean_env GCT_CONFIG_DIR="$DEMO_HOME/config" XDG_CONFIG_HOME="$DEMO_HOME/xdg" \
        PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        nohup "$EXE" >"$DEMO_HOME/app.log" 2>&1 &!
}

case ${1:-} in
reset)
    stop_app
    "$DEMO_HOME/bin/gctd" stop 2>/dev/null || true
    rm -f "$GCT_STATE" "$DEMO_HOME/zsh_history"
    ;;
stop)
    stop_app
    ;;
swap)
    stage_rice "$2" "${3:-}"
    ;;
"")
    print -u2 "usage: launch.sh <rice> [glass] | reset | stop"
    exit 2
    ;;
*)
    stop_app
    stage_bins
    stage_zsh
    stage_rice "$1" "${2:-}"
    start_daemon
    start_app
    ;;
esac
