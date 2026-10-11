#!/bin/zsh
# Clean screen for recording: menubar, Dock, desktop icons hidden;
# restored on `end`.
#
#   demo/shoot.sh begin    stash current autohide prefs, hide both
#   demo/shoot.sh end      restore what `begin` stashed
set -euo pipefail

STASH="$HOME/Library/Application Support/GCT Demo/ui.stash"

prefs() {
    osascript -e "tell application \"System Events\" to tell dock preferences to $1"
}

case ${1:-} in
begin)
    [[ -f $STASH ]] || prefs "get {autohide, autohide menu bar}" > "$STASH"
    prefs "set autohide to true"
    prefs "set autohide menu bar to true"
    # Desktop icons (drives, files) show through glass-mode canvases.
    defaults write com.apple.finder CreateDesktop -bool false
    killall Finder
    ;;
end)
    [[ -f $STASH ]] || exit 0
    IFS=', ' read -r dock bar < "$STASH"
    prefs "set autohide to $dock"
    prefs "set autohide menu bar to $bar"
    defaults delete com.apple.finder CreateDesktop 2>/dev/null || true
    killall Finder
    rm -f "$STASH"
    ;;
*)
    print -u2 "usage: shoot.sh begin|end"
    exit 2
    ;;
esac
