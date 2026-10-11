# Demo reel kit

Scripted, repeatable shoot of GCT. A separate demo canvas (own daemon,
socket, state, config, shell history) runs beside the live one; OBS records
over its websocket; ffmpeg cuts the reel.

```
swift build -c release          # never `make build` mid-session: it rewrites
                                # the live daemon's binary
demo/shoot.sh begin             # hide menubar + Dock (restored by `end`)
demo/launch.sh tokyo-night      # demo canvas in a rice (gruvbox, kanagawa)
"$HOME/Library/Application Support/GCT Demo/venv/bin/python" -I demo/obs.py setup
zsh demo/scenes/01-hero.sh      # each scene: stage -> roll -> choreograph -> wrap
RICE=gruvbox zsh demo/scenes/stills.sh
python3 -I demo/edit/cut.py demo/edit/hype.json
demo/shoot.sh end
```

| Path | What |
|---|---|
| `launch.sh` | demo instance: `<rice> [glass]`, `swap <rice>`, `stop`, `reset` |
| `rices/*.env` | palette per rice: ghostty theme, chrome, status bar, btop, groups |
| `obs.py` | OBS remote: `setup` (native res, HEVC), `rec start|stop`, `shot`, `cursor` |
| `scenes/` | one script per shot; `city.sh` is the shared 40-pane layout |
| `wall.sh` | temporary wallpaper for glass stills, restores the original store |
| `media/` | OpenRouter B-roll + music generator (`gen.py`, `shots.json`) |
| `edit/` | `cut.py` + edit lists; captions are ImageMagick cards |

Output: `~/Movies/GCT Reel/{takes,stills,stock,music,out}`.

Scenes drive the canvas through `gctd camera` / `gctd do <action> dur=`,
so every move is the real code path at a chosen pace. Mouse-only features
(snapping guides, opt-drag create, rubber-band select, group drags, doom
hotkey) need hands: run `obs.py cursor on`, `obs.py rec start`, perform,
`rec stop`.
