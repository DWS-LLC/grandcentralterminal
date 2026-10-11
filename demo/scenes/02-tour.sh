#!/bin/zsh
# Tour: glide between districts at different zooms. Every pane stays live,
# even at 0.1x. Assumes the city is staged (run 01-hero first).
source "${0:A:h}/lib.sh"

act fit-all dur=0.01
hold 2
roll tour
cam btop zoom=0.9 dur=3
hold 1.5
cam pipes zoom=1.4 dur=2.5
hold 1.5
cam build zoom=0.8 dur=3
hold 1.5
cam yazi zoom=0.6 dur=2.5
hold 1
cam zoom=0.1 dur=4
hold 3
wrap
