#!/bin/zsh
# Live rice swap: rewrite config, cmd+shift+r. Canvas, chrome, status
# bar AND terminal palettes change in place.
source "${0:A:h}/lib.sh"
need_city

act fit-all dur=0.01
cam nvim zoom=0.8 dur=0.01
hold 2
roll reload
hold 2
for r in gruvbox kanagawa tokyo-night; do
    "$DEMO/launch.sh" swap $r
    act reload-config
    hold 2.5
done
wrap
