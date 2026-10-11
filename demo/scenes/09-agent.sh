#!/bin/zsh
# Agents: Claude Code runs in a pane and drives GCT itself (gctd open,
# group, dump): spawns its workers beside it, groups them, reports back.
source "${0:A:h}/lib.sh"

PROMPT='Use GCT panes (gctd) for this. Open three panes beside you: 1) name=build running `swift build -c release --build-path /tmp/gct-agent-build`, 2) name=monitor running `dbtop`, 3) name=history running `git log --oneline --graph --color=always -30 | cat; exec zsh`. Group all three together with yourself (`self`) as name=agent-dev color=#bb9af7. Then poll the build pane with gctd dump until it finishes and reply with one line: the result and the time it took.'

wipe
rm -rf /tmp/gct-agent-build
c=$(pane claude 0 0 1500 1100 "claude --dangerously-skip-permissions")
hold 8
cam claude zoom=0.85 dur=0.01
hold 1

roll agent
hold 2
"$G" send claude "$PROMPT"
hold 2
"$G" send claude --no-newline '\r'
# Let it work; the camera pulls back as panes land.
hold 25
act fit-all dur=2
hold 60
act fit-all dur=1.5
hold 5
wrap
