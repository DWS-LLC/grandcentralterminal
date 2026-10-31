# Default keybindings

Every shortcut is rebindable under `[keybinds]` in
`~/.config/gct/config.toml` (see [configuration](configuration.md)).
Format: modifiers `cmd`, `ctrl`, `alt`, `shift` joined with `+`, last part is
the key, e.g. `new-pane = "cmd+shift+t"`. `⌘⇧R` reloads the config live.

## Panes

| Key | Action | Config name |
| --- | --- | --- |
| `⌘T` | new pane | `new-pane` |
| `⌘W` | close focused pane (every selected pane when focused is selected) | `close-pane` |
| `⌘R` | rename focused pane (its group, if it has one) | `rename-pane` |
| `⌘F` | float / re-tile focused pane | `toggle-floating` |
| `⌘⇧H/J/K/L` | new pane on that side of the focused pane | `open-new-window-{left,below,above,right}` |
| `⌘⌃H/J/K/L` | grow focused pane toward left/down/up/right (shoves blockers) | `grow-window-*` |
| `⌘⌃⇧H/J/K/L` | shrink focused pane from that edge | `shrink-window-*` |

## Navigation

| Key | Action | Config name |
| --- | --- | --- |
| `⌘H/J/K/L` | focus nearest pane left/down/up/right | `move-focus-*` |
| `⌘P` | pane switcher (type to filter, ⏎ to jump) | `switcher` |
| `⌘0` | fit all panes | `fit-all` |
| `⌘Z` | focus-zoom pane to a sharp local fullscreen (toggle restores) | `zoom-pane` |
| `⌘⇧Z` | camera-only zoom into the focused pane (it keeps its size, the camera moves) | `camera-zoom-pane` |
| `⌘+` / `⌘-` | per-pane font zoom (ghostty's, carries to new panes) | |

## Selection and groups

| Key | Action | Config name |
| --- | --- | --- |
| `⌘D` | toggle focused pane in multi-select | `toggle-pane-selection` |
| `⌘⇧D` | clear multi-select | `clear-pane-selection` |
| `⌘G` | group staged selection (else rename focused pane's group) | `group-selection` |
| `⌘⇧G` | ungroup | `ungroup` |

## App

| Key | Action | Config name |
| --- | --- | --- |
| `⌘C` / `⌘V` | copy selection (sends `^C` when nothing is selected) / paste | `copy`, `paste` |
| `⌘⇧S` | toggle window snapping (session-only, never moves panes) | `toggle-snapping` |
| `⌘⇧R` | reload `config.toml` | `reload-config` |
| `⌘⇧M` | move the focused pane to its nearest snap target (works with snapping off) | `move-window-to-snap` |
| `⌘⇧A` | relax layout: the whole canvas as a left-to-right tree of the cables | `relax-layout` |
| `⌘Q` | quit the canvas; panes keep running in `gctd` | |

## Mouse and trackpad

| Input | Action |
| --- | --- |
| scroll over a terminal | scroll the terminal |
| trackpad scroll over empty canvas | pan |
| wheel scroll over empty canvas | zoom toward cursor |
| pinch | zoom toward cursor |
| two-finger double-tap | toggle actual size / fit all |
| drag empty space | pan |
| opt-drag empty space | draw a new pane (free corner snaps, live cols×rows pill) |
| right-drag empty space | rubber-band panes into a staged multi-select |
| click-drag inside terminal | select text |
| drag titlebar | move pane (the whole band grabs; corners and side/bottom edges resize) |
| drag edges / corners | resize pane (moving edges snap, guides light) |
| shift+click titlebar | toggle pane in multi-select |
| drag selected titlebar | move the whole selection as a rigid block |
| drag group background | move every member together |
| right-click canvas / group background | one menu: selection actions, group actions, new pane here, arrange, snapping |
| right-click window chrome | add to / remove from group, new group |

The Arrange menu (menubar) tidies the selection, else the focused group,
else everything. Arrange By defaults to Relation, which lays out by cables
(which pane spawned which); pick clean-up / name / directory / status / last
focused / activity instead to sort, as rows / columns / grid (Arrange As).
Picking a shape alone sorts by the last key (Name at first).
Undo Arrange reverts.
