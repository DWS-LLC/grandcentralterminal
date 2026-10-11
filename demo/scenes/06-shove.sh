#!/bin/zsh
# No-overlap: keyboard grow pushes neighbors aside in a cascade, shrink
# hands the room back. Mouse drags never shove (manual shot).
source "${0:A:h}/lib.sh"

wipe
pane grow 0 0 800 560 "cbonsai -l -i -L 30 -t 0.05" >/dev/null
pane b 840 0 800 560 "sleep 1; tty-clock -c -s -C 4" >/dev/null
pane c 1680 0 800 560 "pipes.sh -p 2 -r 0" >/dev/null
pane d 2520 0 800 560 "cbonsai -l -i -L 25 -t 0.07 -w 2" >/dev/null
hold $SETTLE
"$G" focus grow
# Locked-off wide frame with room on the right for the cascade.
cam x=2300 y=200 zoom=0.62 dur=0.01
hold 1

# step ACTION N: repeat a keybind like a held key.
step() {
    repeat $2; do
        act "$1" grow
        hold 0.03
    done
}

roll shove
hold 1.5
step grow-window-right 60
hold 1.5
step grow-window-above 18
hold 1.5
step shrink-window-right 60
hold 2
wrap
