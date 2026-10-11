#!/bin/zsh
# Spawn: open-new-window-{right,below,left} from the focused pane; the
# camera follows each one. New shells inherit cwd and get a command typed.
source "${0:A:h}/lib.sh"

wipe
first=$(pane shell 0 0 1100 700 "fastfetch; exec zsh")
hold $SETTLE
cam "$first" zoom=1 dur=0.01
act zoom-pane "$first"
act zoom-pane "$first"
hold 1

# spawn DIRECTION CMD: split, then type CMD into the new shell.
spawn() {
    local before=$(ids)
    act "open-new-window-$1" dur=1
    hold 1.2
    "$G" send "$(newest "$before")" "$2"
    hold 1.8
}

roll spawn
hold 1
spawn right "dbtop"
spawn below "cbonsai -l -i -L 40 -t 0.06"
spawn left "sleep 1; tty-clock -c -s -C 4"
spawn left "pipes.sh -p 3 -r 0"
spawn above "eza --tree --level 2 --icons=always Sources"
act fit-all dur=1.5
hold 3
wrap
