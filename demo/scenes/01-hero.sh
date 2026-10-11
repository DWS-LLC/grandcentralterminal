#!/bin/zsh
# Hero: one editor at actual size, then the camera pulls back to reveal the
# whole live canvas. Cold-open shot + reel thumbnail.
source "${0:A:h}/lib.sh"
source "${0:A:h}/city.sh"

wipe
stage_city
hold $(( SETTLE * 2 ))
act zoom-pane "$CORE_NVIM"
act zoom-pane "$CORE_NVIM"
cam "$CORE_NVIM" zoom=1 dur=0.01
hold 2

roll hero
hold 2
act fit-all dur=5
hold 3
wrap
still city-fit
