#!/bin/zsh
# Outro: from the whole city, drift out until it's a constellation.
# Self-staged, fit-all twice: a single fit right after staging/rice swap
# has landed off-center, and the zoom-out converges on wherever it starts.
source "${0:A:h}/lib.sh"
source "${0:A:h}/city.sh"

wipe
stage_city
hold $(( SETTLE * 2 ))
act fit-all dur=0.01
hold 2
act fit-all dur=0.01
hold 1

roll outro
hold 1.5
cam zoom=0.04 dur=7
hold 3
wrap
