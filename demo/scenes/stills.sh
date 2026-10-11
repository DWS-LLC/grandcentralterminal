#!/bin/zsh
# Stills for one rice: RICE=gruvbox scenes/stills.sh
#   rice-*   curated six-pane composition (unixporn layout), opaque + glass
#   city-*   the full live canvas, fit + district close-ups
# Glass shots swap the desktop wallpaper; restored at the end.
source "${0:A:h}/lib.sh"
source "${0:A:h}/city.sh"

WALL="$HOME/Movies/GCT Reel/stock/keyframes/wall-$RICE.jpg"

# Curated composition: editor left, fetch + monitor right, toys below.
stage_rice() {
    pane nvim 0 0 1500 1100 "nvim +/scriptedCamera Sources/Canvas/CanvasView.swift" >/dev/null
    pane fastfetch 1540 640 1000 460 "fastfetch; exec zsh" >/dev/null
    pane btop 1540 0 1000 600 "dbtop" >/dev/null
    pane bonsai 0 -460 740 420 "cbonsai -l -i -L 40 -t 0.04" >/dev/null
    pane clock 780 -460 720 420 "sleep 1; tty-clock -c -s -C 4" >/dev/null
    pane pipes 1540 -460 1000 420 "pipes.sh -p 3 -r 0" >/dev/null
}

# Opaque rice.
"$DEMO/launch.sh" "$RICE"
hold 3
wipe
stage_rice
hold $(( SETTLE * 3 ))
act fit-all dur=0.01
hold 1
still rice-opaque
cam nvim zoom=1 dur=0.01
hold 1
still rice-nvim
cam btop zoom=1.4 dur=0.01
hold 1
still rice-btop

# Glass rice over the matching wallpaper.
"$DEMO/wall.sh" set "$WALL"
"$DEMO/launch.sh" "$RICE" glass
hold 4
# Fresh panes: a relaunch reattach resizes every PTY (tty-clock can't).
wipe
stage_rice
hold $(( SETTLE * 3 ))
act fit-all dur=0.01
hold 2
still rice-glass
cam bonsai zoom=1.2 dur=0.01
hold 1
still rice-glass-bonsai
"$DEMO/wall.sh" restore

# City, opaque.
"$DEMO/launch.sh" "$RICE"
hold 3
wipe
stage_city
hold $(( SETTLE * 3 ))
act fit-all dur=0.01
hold 1
still city-fit
cam nvim zoom=0.7 dur=0.01
hold 1
still city-editor
cam btop zoom=0.6 dur=0.01
hold 1
still city-monitor
cam zoom=0.12 dur=0.01
hold 1
still city-far
