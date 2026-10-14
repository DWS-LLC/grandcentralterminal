# Demo kit

Scripted, repeatable screenshots of GCT. A separate demo canvas (own daemon,
socket, state, config, shell history) runs beside the live one; OBS captures
over its websocket.

```
swift build -c release          # never `make build` mid-session: it rewrites
                                # the live daemon's binary
demo/shoot.sh begin             # hide menubar + Dock (restored by `end`)
demo/launch.sh tokyo-night      # demo canvas in a rice (gruvbox, kanagawa)
RICE=gruvbox zsh demo/scenes/stills.sh
demo/shoot.sh end
```

| Path | What |
|---|---|
| `launch.sh` | demo instance: `<rice> [glass]`, `swap <rice>`, `stop`, `reset`, `hosts up\|down` (stand-in remotes) |
| `rices/*.env` | palette per rice: ghostty theme, chrome, status bar, btop, groups |
| `obs.py` | OBS remote: `setup` (native res), `shot`, `cursor` |
| `scenes/` | one script per scene; `city.sh` is the shared 40-pane layout |
| `wall.sh` | temporary wallpaper for glass stills, restores the original store |
