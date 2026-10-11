#!/bin/zsh
# Temporary desktop wallpaper for glass-mode stills, fully restorable.
#
#   demo/wall.sh set <image>   back up the wallpaper store (once), set image
#   demo/wall.sh restore       put the original store back, restart agent
#
# Folder rotations don't round-trip through System Events, so the backup
# is the wallpaper store plist itself.
set -euo pipefail

STORE="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
BACKUP="$HOME/Library/Application Support/GCT Demo/wallpaper-Index.plist"

case ${1:-} in
set)
    [[ -f $BACKUP ]] || cp "$STORE" "$BACKUP"
    # System Events can be mid-launch (-600); give it a few tries.
    for _ in 1 2 3; do
        osascript -e "tell application \"System Events\" to tell every desktop to set picture to POSIX file \"${2:A}\"" && exit 0
        sleep 1
    done
    exit 1
    ;;
restore)
    [[ -f $BACKUP ]] || exit 0
    cp "$BACKUP" "$STORE"
    killall WallpaperAgent 2>/dev/null || true
    rm -f "$BACKUP"
    ;;
*)
    print -u2 "usage: wall.sh set <image> | restore"
    exit 2
    ;;
esac
