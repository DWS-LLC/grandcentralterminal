#!/bin/zsh
# Groups + floating: staged multi-select becomes a colored group; a loose
# pane floats over its loose neighbors (floaters never cross foreign group
# bounds, by design). Rubber-band select + group drags are manual shots.
source "${0:A:h}/lib.sh"

wipe
a=$(pane api 0 0 900 560 "cbonsai -l -i -L 30 -t 0.05 -w 2")
b=$(pane worker 940 0 900 560 "pipes.sh -p 2 -r 0")
c=$(pane db 0 -600 900 560 "sleep 1; tty-clock -c -s -C 4")
d=$(pane logs 940 -600 900 560 "git log --graph --oneline --color=always -30 | cat; exec zsh")
pane notes 2160 0 800 560 "glow -s dark README.md; exec zsh" >/dev/null
pane scratch 2160 -600 800 560 "cbonsai -l -i -L 25 -t 0.08" >/dev/null
hold $SETTLE
cam x=1480 y=-20 zoom=0.78 dur=0.01
hold 1

roll groups
hold 1.5
for p in api worker db logs; do
    act toggle-pane-selection $p
    hold 0.45
done
hold 1
act clear-pane-selection
group backend 2 "$a" "$b" "$c" "$d"
hold 2.5
act toggle-floating scratch
hold 0.8
"$G" move scratch rect=2060,-280,800,560
hold 2.5
act toggle-floating scratch
hold 2.5
wrap
