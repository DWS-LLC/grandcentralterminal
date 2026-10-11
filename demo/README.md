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
demo/launch.sh hosts up && zsh demo/scenes/12-formation.sh   # remote panes
blender -b --python demo/edit/airframe.py -- all --fast      # hero CG
python3 demo/edit/sfx.py                                     # sound design
python3 -I demo/edit/cut.py demo/edit/flight.json
demo/shoot.sh end
```

| Path | What |
|---|---|
| `launch.sh` | demo instance: `<rice> [glass]`, `swap <rice>`, `stop`, `reset`, `hosts up\|down` (stand-in remotes) |
| `rices/*.env` | palette per rice: ghostty theme, chrome, status bar, btop, groups |
| `obs.py` | OBS remote: `setup` (native res, ProRes), `rec start|stop`, `shot`, `cursor` |
| `scenes/` | one script per shot; `city.sh` is the shared 40-pane layout |
| `wall.sh` | temporary wallpaper for glass stills, restores the original store |
| `media/` | OpenRouter B-roll + music generator (`gen.py`, `shots.json`) |
| `edit/` | `cut.py` + edit lists (`flight.json` current; `engineering.json`, `launch.json` older cuts) |
| `edit/airframe.py` | Blender: GCT as a machined airframe in a dark hangar (reveal, macro, top, x-ray, formation) + callout tracks |
| `edit/sfx.py` | synthesized effects (hit, boom, whoosh, riser, spool, lock, tick, servo); shots place them with `sfx` |
| `edit/titles.py` | kinetic type: decode headlines, corner labels, typed `KEY=VALUE` mono, footer |
| `edit/stack.py` | Blender: exploded gctd → panes → canvas sheets on light grey (`render:stack`) |
| `edit/matte.swift` | person mattes for generated plates (Vision), so the actor stays in front of composited screens |
| `edit/track.swift` | camera track for "locked" Veo plates (patch registration → scale + offset per frame) |

Output: `~/Movies/GCT Reel/{takes,stills,stock,music,render,out}`.

Scenes drive the canvas through `gctd camera` / `gctd do <action> dur=`,
so every move is the real code path at a chosen pace. Mouse-only features
(snapping guides, opt-drag create, rubber-band select, group drags, doom
hotkey) need hands: run `obs.py cursor on`, `obs.py rec start`, perform,
`rec stop`.

Generated B-roll gets the real app on its screens: a shot's `screen` block
corner-pins a take onto the plate's wall (`quad`, clockwise), follows the
plate's drift (`track` patches on static set), keeps the actor (`matte`) and
props (`holdouts`, frame-0 polygons) in front. A locked-off plate needs no
`track`; holdouts also trim a curved monitor's glass edge.

The flight cut has no generated stand-ins: every shot is the product (CG
airframe or a real take). Shoot in one rice (tokyo-night). Formation's
remote hosts are local TCP daemons (`launch.sh hosts up`), so no real
machine is on camera; camera moves to remote panes use world points
(name lookups only resolve local panes).

A shot's `type` list is kinetic type (see `edit/titles.py`); dark `ink` +
`"type_shadow": false` on light plates. Veo 4K plates carry 8px black bars
top and bottom; `cut.py` punches stock in 0.8% by default.

OBS records ProRes 422: the HEVC engine can't hold 60fps at 6400x3600 and
silently drops frames. Never cut the persist take's quit gap (3.9-8.0s): it
shows whatever sits behind the demo app.
