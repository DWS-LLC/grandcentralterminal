#!/bin/zsh
# Focus zoom: cmd+z takes a pane to a SHARP local fullscreen (surface
# reflows, no raster upscale) and back. Assumes the city is staged.
source "${0:A:h}/lib.sh"

act fit-all dur=0.01
hold 2
roll zoom
"$G" focus nvim
hold 2
act zoom-pane nvim
hold 3.5
act zoom-pane nvim
hold 2
act fit-all dur=1.5
hold 2
wrap
