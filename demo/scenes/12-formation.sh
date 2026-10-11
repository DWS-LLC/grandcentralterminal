#!/bin/zsh
# Formation: remote hosts join the canvas one at a time, each in its own
# color, around the local lead. Hosts are stand-in daemons on this Mac
# (launch.sh hosts up), so no real machine appears on camera.
#
#                 ┌ build-01 ┐   ┌── lead (local) ──┐   ┌ gpu-02 ┐
#                 └──────────┘   └──────────────────┘   └────────┘
#                                ┌──── edge-03 ─────┐
#                                └──────────────────┘
source "${0:A:h}/lib.sh"

# hpane HOST NAME X Y W H CMD: open a pane on a host daemon over TCP.
hpane() {
    local spec=${HOSTS_PORTS[$1]} dir="$DEMO_HOME/hosts/$1"
    "$G" --tcp="127.0.0.1:$spec" --token="$(<"$dir/token")" \
        open name="$2" rect="$3,$4,$5,$6" cwd="$REPO" cmd="$7" >/dev/null
}
typeset -A HOSTS_PORTS=(build-01 7431 gpu-02 7432 edge-03 7433)

# hwipe: close every pane on every host (local wipe can't see them).
hwipe() {
    local h id tcp
    for h in ${(k)HOSTS_PORTS}; do
        tcp=(--tcp="127.0.0.1:${HOSTS_PORTS[$h]}" --token="$(<"$DEMO_HOME/hosts/$h/token")")
        for id in $("$G" $tcp list | awk '$1 ~ /^[0-9A-F-]{36}$/ {print $1}'); do
            "$G" $tcp close "$id" 2>/dev/null || true
        done
    done
}

# focus_new on|off: new panes steal focus (and the camera) or not. Off
# for this take: wingmen land while the camera holds the formation.
focus_new() {
    local v=$([[ $1 == on ]] && print true || print false)
    sed -i '' "s/^move-focus-on-new-window = .*/move-focus-on-new-window = $v/" \
        "$DEMO_HOME/config/config.toml"
    "$G" do reload-config >/dev/null
}

wipe
"$DEMO/launch.sh" hosts up
hwipe
focus_new off
hold 2

# Lead: the local editor + monitor.
nvim=$(pane nvim 0 0 1500 940 "nvim +/scriptedCamera Sources/Canvas/CanvasView.swift")
btop=$(pane btop 1540 0 900 940 "dbtop")
group lead 1 "$nvim" "$btop"
hold $SETTLE
cam nvim zoom=0.42 dur=0.01
hold 1

roll formation
hold 2
# Wingmen join one by one; the camera opens up as each locks in.
hpane build-01 build -2300 120 1300 820 "git log --graph --oneline --decorate --color=always -60 | cat; exec zsh"
hpane build-01 pipes -2300 -760 1300 820 "pipes.sh -p 3 -r 0 -f 40"
hold 1.5
act fit-all dur=1.6
hold 1
hpane gpu-02 gpu 2560 120 1100 820 "dbtop"
hpane gpu-02 clock 2560 -760 1100 820 "sleep 1; tty-clock -c -C 6 -s -b"
hold 1.5
act fit-all dur=1.4
hold 1
hpane edge-03 edge -600 -1260 1700 900 "cbonsai -l -i -L 60 -t 0.05 -w 3"
hpane edge-03 logs 1160 -1260 1280 900 "eza --tree --level 2 --icons=always Sources; exec zsh"
hold 1.5
act fit-all dur=1.4
hold 3
# Into a wingman: its host title + color chrome up close. Camera by
# world point (name lookups only see local panes); rect is bottom-left.
cam x=-1650 y=530 zoom=1.5 dur=2
hold 3
act fit-all dur=1.6
hold 3
wrap
focus_new on
