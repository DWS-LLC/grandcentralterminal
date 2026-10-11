# The "city": one dense, live canvas reused by the hero, canvas, outro and
# stills. Four colored districts at the core, a ring of live panes around.
#
#          ring  ring  ring  ring  ring
#   ring  ┌─files─┐ ┌──editor──┬─git─┐ ┌─build─┐  ring
#   ring  │ docs  │ │   nvim   │ lazy│ │ swift │  ring
#   ring  └───────┘ └──────────┴─────┘ └───────┘  ring
#   ring  ┌──────monitor: btop, clock, bonsai, pipes──────┐  ring
#          ring  ring  ring  ring  ring
#
# World points, y up. Screen is 3200x1800pt, so the core fills ~1 screen
# at zoom 0.5 and the ring pushes fit-all out to ~0.2.

CORE_NVIM=""

stage_city() {
    local nvim lazy log build btop clock bonsai pipes yazi docs fetch tree

    # Editor district: the code that draws this very canvas.
    nvim=$(pane nvim 0 0 1640 1040 "nvim +/scriptedCamera Sources/Canvas/CanvasView.swift")
    lazy=$(pane lazygit 1680 0 1000 1040 "lazygit")
    group editor 1 "$nvim" "$lazy"

    # Build district: a real from-scratch compile + history.
    build=$(pane build 2840 540 1180 500 \
        "swift build -c release --build-path '$DEMO_HOME/scratch-build' 2>&1 | tee /dev/null; exec zsh")
    log=$(pane history 2840 0 1180 500 \
        "git log --graph --oneline --decorate --color=always -40 | cat; exec zsh")
    group build 2 "$build" "$log"

    # Monitor district: everything that moves on its own.
    btop=$(pane btop 0 -900 1300 840 "dbtop")
    clock=$(pane clock 1340 -460 660 400 "sleep 1; tty-clock -c -C 4 -s -b")
    bonsai=$(pane bonsai 1340 -900 660 400 "cbonsai -l -i -L 50 -t 0.1 -w 3")
    pipes=$(pane pipes 2040 -900 640 840 "pipes.sh -p 3 -r 0 -f 30")
    group monitor 3 "$btop" "$clock" "$bonsai" "$pipes"

    # Files district.
    yazi=$(pane yazi 2840 -900 1180 840 "yazi")
    docs=$(pane docs -1360 -900 1200 840 "glow -s dark README.md; exec zsh")
    fetch=$(pane fastfetch -1360 0 1200 1040 "fastfetch; exec zsh")
    group files 4 "$docs" "$fetch"
    tree=$(pane tree 2840 1080 1180 560 "eza --tree --level 2 --icons=always Sources; exec zsh")

    stage_ring
    CORE_NVIM=$nvim
}

# Outer ring: small live panes far out, read as texture when zoomed out.
RING_CMDS=(
    "pipes.sh -p 2 -r 0 -f 40"
    "sleep 1; tty-clock -c -C 6 -s"
    "cbonsai -l -i -L 40 -t 0.05"
    "dbtop"
    "pipes.sh -p 4 -t 1 -r 0 -f 60"
    "cbonsai -l -i -L 30 -t 0.07 -w 2"
    "sleep 1; tty-clock -c -C 5 -s"
    "fastfetch; exec zsh"
)
stage_ring() {
    local i=0 x y
    for x in -3100 -1750 -400 950 2300 3650 5000; do
        for y in 1900 -2100; do
            pane "ring-$i" $x $y 1200 760 "${RING_CMDS[$(( i % ${#RING_CMDS} + 1 ))]}" >/dev/null
            i=$(( i + 1 ))
        done
    done
    for y in 1080 -100 -1280; do
        pane "ring-$i" -3100 $y 1200 760 "${RING_CMDS[$(( i % ${#RING_CMDS} + 1 ))]}" >/dev/null
        i=$(( i + 1 ))
        pane "ring-$i" 4380 $(( y - 400 )) 1200 760 "${RING_CMDS[$(( i % ${#RING_CMDS} + 1 ))]}" >/dev/null
        i=$(( i + 1 ))
    done
}
