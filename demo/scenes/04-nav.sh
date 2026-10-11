#!/bin/zsh
# Navigation: directional focus moves (cmd+h/j/k/l) fly + fit the camera,
# then the cmd+p switcher. Assumes the city is staged.
source "${0:A:h}/lib.sh"

"$G" focus nvim
hold 2
roll nav
hold 1
for dir in right right below left left above; do
    act "move-focus-$dir" dur=1.1
    hold 1.6
done
act switcher
hold 2.5
act switcher
"$G" focus clock
hold 2.5
wrap
