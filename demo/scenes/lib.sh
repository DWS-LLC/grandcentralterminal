# Shared scene helpers. Source from a scene script:
#   source "${0:A:h}/lib.sh"
#
# Every scene: wipe -> stage panes (world points, y up) -> roll -> choreograph
# via gctd camera/do -> wrap. Takes land in ~/Movies/GCT Reel/takes.

DEMO=${${(%):-%x}:A:h:h}
REPO=${DEMO:h}
DEMO_HOME="$HOME/Library/Application Support/GCT Demo"
export GCT_SOCK="$DEMO_HOME/daemon.sock"
G="$DEMO_HOME/bin/gctd"
OBS=("$DEMO_HOME/venv/bin/python" -I "$DEMO/obs.py")
TAKES="$HOME/Movies/GCT Reel/takes"
STILLS="$HOME/Movies/GCT Reel/stills"
RICE=${RICE:-tokyo-night}
source "$DEMO/rices/$RICE.env"

# Settle time after staging: shells print prompts, TUIs paint first frame.
SETTLE=4

# Close every pane + group: each scene starts from an empty canvas.
wipe() {
    local id
    for id in $("$G" list | awk '$1 == "group" {print $2}'); do
        "$G" ungroup "$id" 2>/dev/null || true
    done
    for id in $("$G" list | awk '$1 ~ /^[0-9A-F-]{36}$/ {print $1}'); do
        "$G" close "$id" 2>/dev/null || true
    done
    sleep 1
}

# pane NAME X Y W H CMD -> prints id. Static commands keep a shell after
# ("fastfetch; exec zsh") or the pane closes when they exit.
pane() {
    "$G" open name="$1" rect="$2,$3,$4,$5" cwd="${PANE_CWD:-$REPO}" cmd="$6"
}

# group NAME COLOR_INDEX PANE... (colors from the rice palette, 1-based)
group() {
    local name=$1 color=${GROUP_COLORS[$2]}
    shift 2
    "$G" group "$@" name="$name" color="$color" >/dev/null
}

# cam/act block for their own dur= so holds are pure pauses:
#   cam nvim zoom=1 dur=3; hold 2   -> 3s glide, then 2s still
cam() { "$G" camera "$@"; wait_dur "$@"; }
act() { "$G" do "$@"; wait_dur "$@"; }
wait_dur() {
    local a
    for a; do
        [[ $a == dur=* ]] && sleep "${a#dur=}"
    done
    return 0
}

# Hold for the edit: real time between moves, so cuts have handles.
hold() { sleep "${1:-1}"; }

# roll NAME: start recording; wrap: stop + move the take to takes/NAME.mov.
TAKE_NAME=""
roll() {
    TAKE_NAME=$1
    mkdir -p "$TAKES"
    "${OBS[@]}" rec start || exit 1
    hold 1
}
wrap() {
    hold 1
    local raw
    raw=$("${OBS[@]}" rec stop)
    mv "$raw" "$TAKES/$TAKE_NAME-$RICE.mov"
    print "take: $TAKES/$TAKE_NAME-$RICE.mov"
}

# still NAME: 6400x3600 PNG of the screen.
still() {
    "${OBS[@]}" shot "$STILLS/$RICE/$1.png" >/dev/null
    print "still: $STILLS/$RICE/$1.png"
}

# Pane ids, for diffing around actions that create panes.
ids() { "$G" list | awk '$1 ~ /^[0-9A-F-]{36}$/ {print $1}' | sort; }

# newest BEFORE_IDS: the pane id that appeared since BEFORE_IDS.
newest() { comm -13 <(print -l ${(f)1}) <(ids) | head -1; }

# Demo app pid (the live app runs from /Applications, never matched).
demo_app_pid() { pgrep -f "GCT Demo/Grand Central Terminal.app/Contents/MacOS" | head -1; }

# need_city: scenes that wipe (spawn, shove, groups...) leave no city behind.
# Restage it when the core editor is missing, so scenes run in any order.
need_city() {
    "$G" focus nvim >/dev/null 2>&1 && return 0
    source "$DEMO/scenes/city.sh"
    wipe
    stage_city
    hold $(( SETTLE * 2 ))
}
