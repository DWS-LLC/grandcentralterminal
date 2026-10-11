#!/bin/zsh
# Persistence: quit the app mid-build, relaunch, the build never stopped
# and scrollback replays. The tmux promise, on a canvas.
source "${0:A:h}/lib.sh"

wipe
# A build left over from the last take holds SwiftPM's lock.
pkill -f 'swift-build .*--build-path .*GCT Demo/persist' || true
b=$(pane build 0 0 1600 1000 \
    "rm -rf '$DEMO_HOME/persist-build'; swift build -c release -j 1 --build-path '$DEMO_HOME/persist-build' 2>&1 | cat; exec zsh")
m=$(pane monitor 1640 0 1000 1000 "dbtop")
group build 2 "$b" "$m"
hold 6
# Same frame before and after the relaunch: reads as "nothing changed".
act fit-all dur=0.01
hold 1

# The quit exposes the desktop: show the rice wallpaper, not the user's.
"$DEMO/wall.sh" set "$HOME/Movies/GCT Reel/stock/keyframes/wall-$RICE.jpg"
hold 1

roll persist
hold 3
kill -TERM $(demo_app_pid)
hold 3
"$DEMO/launch.sh" "$RICE" >/dev/null
hold 4
act fit-all dur=0.01
hold 5
wrap
"$DEMO/wall.sh" restore
