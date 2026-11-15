# Lua scripting

`gctd lua` runs a Lua script against the daemon: open panes, wait on programs,
react to events, hold timers. It follows Rex's `rex do` closely (same `ev`/`ctx`
shapes, same `nil, err` convention, same `exec` and timer semantics), so most
Rex scripts port by changing the namespace and the calls that name Rex's
sessions and windows.

```sh
gctd lua build.lua target=release   # a file: ends in .lua or has a slash
gctd lua -e 'return gct.pane.list{}'   # inline
echo 'return 40 + 2' | gctd lua -      # stdin
```

The script runs in the `gctd lua` process, a plain client of the daemon. The
daemon never executes script code, so a runaway script costs one process and
leaves your shells alone. Lua 5.4. Scripts are not sandboxed (they are you, with
`io`, `os` and `require`), except `io.popen` and `os.execute`, which raise: use
`gct.exec`.

```lua
-- Run the tests beside you, raise the pane if they fail.
local p = gct.pane.open{ name = "tests", cmd = gct.args.cmd or "make test" }
local r = gct.pane.wait{ pane = p.pane_id, timeout = 600 }
if r and r.exit_code ~= 0 then gct.pane.focus{ pane = p.pane_id } end
return { exit_code = r and r.exit_code }
```

```lua
-- Name every pane after its directory.
gct.on("terminal.pwd_changed", function(ctx, ev)
  local dir = ev.pwd:match("([^/]+)/?$")
  if dir then gct.pane.rename{ pane = ev.pane_id, name = dir } end
end)
```

## Running

| Flag | |
|---|---|
| `key=value` | `gct.args.key`. `3`, `1.5`, `true`, `false` keep their type, the rest is text |
| `--args json` / `--args @file` | arguments as JSON, merged over `key=value` |
| `--json` | indent the returned value |
| `--for 10m` | stop (exit 0) after that long |
| `--fail-fast` | exit 1 at the first handler or timer error, instead of printing it and carrying on |
| `--pane <pane>` | act as that pane. Default: the pane the script was started from |

A value the script returns prints as JSON; returning nothing prints nothing. An
uncaught error prints and exits 1. With `gct.on` handlers or timers the script
stays up until `gct.stop(code)`, `--for`, `^C` (130) or the daemon going away
(4). `--tcp host:port --token ...` aims it at a remote daemon like any other
verb.

`gct.stop(code)` leaves at once, even inside a `pcall`.

## Panes

Calls take and return tables. A failure returns `nil, message` and never raises,
so check the second value. `pane` takes what `gctd` takes: a uuid, a unique id
prefix or suffix, an exact name, or `"self"`. Left out, it is the pane the script
acts for: its own, or inside a handler the pane the event came from.

| Call | |
|---|---|
| `gct.pane.open{cmd, name, cwd, side, size, rect, group, parent, host, keep_open}` | like `gctd open`. Returns `{pane_id}`. `side` is `right`, `left`, `above` or `below`; `size` is `"w,h"` or `"33%,100%"` |
| `gct.pane.close{pane}` / `rename{pane, name}` / `focus{pane}` | |
| `gct.pane.send{pane, text, enter=true, paste=false}` | keys, not a command |
| `gct.pane.dump{pane, limit, strip_ansi}` | `{text, truncated, dropped, bytes}` |
| `gct.pane.notify{pane, title, body}` | desktop notification; clicking focuses the pane |
| `gct.pane.move{pane, rect={x,y,w,h}}` | |
| `gct.pane.wait{pane, timeout}` | `{exit_code}`, or `{closed=true}` for a pane closed without a status. `nil, "timeout"` |
| `gct.pane.list{}` / `inspect{pane}` | the shapes `gctd list --json` and `gctd inspect --json` print |
| `gct.group.create{panes, name, color}` / `delete{group}` | |
| `gct.tie.create{parent, children, at}` / `delete{tie}` | |
| `gct.view{}` / `gct.hosts{}` | everything the daemon knows / peers and whether each link is up |
| `gct.camera{pane, x, y, zoom, dur}` / `font{delta, pane}` / `session{name}` | the canvas verbs |
| `gct.client.queue(name[, {pane, dur}])` | run a keybind action (`fit-all`, `zoom-pane`, ...) |
| `gct.client.press(keys)` | type keys on the canvas: `"cmd+d"`, or a sequence `"ctrl+b>c"`. Bound keys run, the rest fall away |
| `gct.bind` / `unbind` / `mode` / `bindings` / `modes` | key bindings and modes, [below](#keys) |
| `gct.call(method[, args])` | any frame a client may send, by its protocol name, with a JSON body. No guard rails |
| `gct.block.call(creator, method[, args])` | a method on a pane's terminal, [below](#terminal-methods) |
| `gct.servers()` / `gct.server(label)` | the peers' labels / the calls above aimed at one peer, [below](#peers) |

### Terminal methods

`gct.block.call("com.superlogical.terminal", method, {pane = ...})`, as in Rex.
`pane` is optional in a handler, like everywhere; `block_id` works too. It
returns a table, or `nil, message`.

| Method | Returns / does |
|---|---|
| `title` | `{title}` as last set (needs the app; `""` before it has said) |
| `pwd` | `{pwd, cwd}`: a `file://` URL and the plain path |
| `process` | `{foreground = {name, cmd, cwd}, exited}` |
| `size` | `{cols, rows, width, height}`, width and height in points. Known to the app only |
| `program_status` | `{records = {...}}`: every [OSC 7501](https://www.superlogical.com/rex/docs/build/program-status) record the pane holds, by id |
| `format{format="text"\|"vt", limit}` | `{format, text, truncated, ...}`. It is what the program printed, not the drawn screen: `text` has the escapes stripped, `vt` keeps them. `html` is refused |
| `write{text}` | bytes as typed, no newline added |
| `reset` | resets the terminal, on screen only |
| `set_theme{foreground, background, cursor, palette}` | colors as `#rrggbb`; `palette` is a list, first entry is color 0. On screen only |
| `list_dir{path, hidden}` | `{path, dirs}`: the directories under `path` (default the pane's cwd). Reads the disk `gctd lua` runs on; refused for a pane on a peer |
| `resize` | always refused: the canvas sizes terminals. Use `gct.pane.move` |

`size` and `program_status` come from the app. The first call asks it to say again
what it knows and waits up to a second; with no app attached the answer is empty
(`size` returns an error) and later calls don't wait again.

### Peers

`gct.servers()` lists the `[host.<name>]` peers. `gct.server(label)` returns a
table with `pane`, `layout`, `block`, `view` and `call`, all aimed at that peer:
`pane.open` and `layout.open` run there, `pane.list` and `view` show only its
panes, and every pane call must name its pane (nothing defaults to the calling
pane) and refuses one that runs elsewhere. An unknown label raises. Declaring a
host from a script is not possible: `gct.host{...}` does nothing (with a warning)
while the script first runs and raises afterwards, as `rex.host` does outside the
config file.

### Layouts

Rex's builders, spread over canvas panes. `horizontal(ratio, a, b)` gives `a` the
left `ratio` of the width; `vertical(ratio, a, b)` gives `a` the top share.

```lua
local L = gct.layout
gct.layout.open{
  name = "work",                      -- a group around the panes
  layout = L.horizontal(0.6,
    L.block{ command = "nvim" },
    L.vertical(0.5, L.block{ command = "npm run dev" }, L.block{})),
}
```

A block takes `command` (a string, or a list), `cwd`, `label`, `initial_input`
and `exit = { on_completion = false }` to keep the pane after its program ends.
`layout.open` also takes `parent`, `size`, `side` and `rect` like `pane.open`.
Returns `{pane_ids, group_id}`.

## Events

`gct.on(event, fn)` calls `fn(ctx, ev)` for each event. Register during the
first run only; `gct.on` raises afterwards. Handlers run one at a time, and
`gct.wait` or `gct.sleep` inside one holds up the rest. A misspelled event name
is never an error: the handler just never fires.

`ev` has `type`, `name` (the type without `terminal.`), `pane_id`, and the
event's own fields both flat and under `ev.payload`. `ctx.pane_id` is the pane
the event came from, and what calls inside the handler default to. `ctx.origin`
is `event`, `timer` or `action`.

| Event | Fires when | Fields |
|---|---|---|
| `pane_created` | a pane appears | `host`, `cwd`, `pane_name` |
| `pane_closed` | a pane goes away | |
| `pane_renamed` | a pane is renamed | `pane_name`, `old_name` |
| `pane_link_changed` | a proxy pane's host link drops or returns | `offline` |
| `pane_focused` | focus moves to a pane (canvas) | |
| `group_created`, `group_changed` | a group appears or changes | `group_id`, `group_name`, `members` |
| `group_closed` | a group is dissolved | `group_id` |
| `tie_changed`, `tie_removed` | a tie appears, changes, goes | `tie_id` |
| `host_up`, `host_down` | a peer link comes up or drops | `host` |
| `view_changed` | the layout changes in any way (bursts coalesce) | `revision` |
| `terminal.child_exited` | the pane's program ends | `exit_code` (128+signal when killed), `kept` |
| `terminal.pwd_changed` | the working directory changes | `pwd` (a `file://` URL), `cwd` |
| `terminal.process_changed` | the foreground command changes | `foreground` = `{name, cmd, cwd}`, nil when idle |
| `terminal.title_changed` | a program sets the title (canvas) | `title` |
| `terminal.bell` | a bell rings (canvas) | |
| `terminal.desktop_notification` | a program asks for a notification (canvas) | `title`, `body` |
| `terminal.progress_report` | a program reports progress, OSC 9;4 (canvas) | `state` (`set`, `remove`, `error`, `indeterminate`, `pause`), `progress` (0-100, nil when none) |
| `terminal.clipboard_written` | a program writes the clipboard, once allowed (canvas) | `text`, cut at 64 KiB |
| `terminal.program_status_changed` | a program reports or updates its status, OSC 7501 (canvas) | `id` (`""` is the root), `record` = `{id, state, kind, progress, app, title, msg}`, `reason` |
| `terminal.program_status_removed` | records go away (canvas) | `ids`, `reason` |

`program_status_changed` has `reason` `report`, or `snapshot` when a script's
first `size` or `program_status` call made the app say again what it holds.
`program_status_removed` has `clear` (the program sent `state=clear`), `prompt`
(a new shell prompt ended `working` and `blocked`), `reset` (RIS), `input` (you
typed, so `done` and `error` served their purpose) or `evicted` (past 256
records).

`terminal_event` (or Rex's `block_event`) matches every `terminal.*` event.

The two kinds of source differ. Daemon events (everything but the ones marked
canvas) fire whether or not an app is attached. Canvas events come from the app
and need it running and protocol 10 on both ends; an older app or daemon simply
never sends them. A kept pane (`keep_open`) fires `terminal.child_exited` once,
when its program ends, and `pane_closed` when you close it.

`gct.wait(event[, filter][, timeout])` blocks for one event and returns
`ev, ctx`, or `nil, "timeout"`. `filter` is a table of fields that must match
(`{pane_id = id}`) or a function `filter(ev, ctx)`. Events that arrived while the
script was busy are still there to be waited on, so there is no race between
opening a pane and waiting for it. An event `wait` takes is not also handed to
`on` handlers.

## Keys

A script can bind keys. They live on the canvas for as long as the script runs
and vanish with it, however it ends. A script that has bindings stays up, like
one with handlers.

```lua
gct.bind("cmd+shift+n", "new-pane")                      -- a built-in action
gct.bind("ctrl+b>c", "new-pane")                         -- a sequence
gct.bind("ctrl+b>z", function(ctx, ev) gct.client.queue("zoom-pane") end)

gct.mode("resize", { exclusive = true })
gct.bind("cmd+alt+r", "client.mode.enter", { name = "resize" })
gct.bind("resize/h", "grow-window-left")
gct.bind("resize/enter", "client.mode.exit")
```

| Call | |
|---|---|
| `gct.bind(key, action[, args])` | a key to a named action. The built-ins are the ones `[keybinds]` names ([keybindings](keybindings.md)); anything else is an action the script defined with `gct.action`, called as `fn(ctx, args)` |
| `gct.bind(key, fn)` | a key to a function (not inside a mode: bind an action there), called as `fn(ctx, ev)`. Return `true` to keep the key; anything else lets it through to the terminal (for a sequence, only the last key). `ev.keybinding` is the key hit; for a sequence, `ev.prefix` lists the keys before it; `ctx.pane_id` is the focused pane, when it lives on the script's host |
| `gct.unbind(key[, target])` | removes this script's bindings at `key` (only those with that action name or function, if given) and returns how many. With no target it also stops whatever else is on that key: a default, or a binding outside the mode. A later `bind` wins again |
| `gct.unbind{mode = name}` | the whole mode: bindings, blocks, options |
| `gct.unbind(binding)` | one binding, as `gct.bindings()` returned it |
| `gct.mode(name[, {exclusive}])` | declares a mode. `exclusive` swallows every key the mode doesn't bind |
| `gct.bindings([{key, mode, action}])` | what this script bound, oldest first: `{key, mode, action \| fn, args, source}` |
| `gct.modes()` | `{name, exclusive, source}` for each mode declared or bound into |

**Keys.** `cmd`, `ctrl`, `alt`, `shift` joined with `+`, then the key: a
character, or `space`, `tab`, `enter`, `escape`, `delete`, `left`, `right`,
`up`, `down`, `f1`-`f12`. `shift+5` is the 5 key. Sequences join keys with `>`
(`ctrl+x>ctrl+k>s`); `escape` cancels, a key the sequence doesn't continue with
cancels, and so does waiting: a half-typed sequence is dropped after
`sequence-timeout` ([configuration](configuration.md), 2s by default). A readout at the bottom of the canvas shows
the modes in force and the keys typed so far. `>` itself is `shift+.`.

**Modes.** `mode/key` binds inside a mode (`resize/left`, `nav/g>g`); a mode
exists once something is bound in it. `client.mode.enter` takes `{name, once}`
(`once` leaves after one shortcut), `client.mode.exit` leaves the newest,
`client.mode.exit_all` leaves all. Modes stack, newest checked first, and
`escape` leaves the current one unless it binds escape itself. Mode names are
lowercase letters, digits, `_` and `-`. Nothing is ever stuck in a mode whose
script is gone.

**Conflicts.** A key runs an action or opens a sequence, never both: the newest
binding wins, and the older one comes back if the newer goes. A script's
bindings beat `config.toml`'s, and a script that started later beats an earlier
one.

A key bound to a function waits for the script. The canvas holds it, and any
keys typed behind it, until the function answers: `true` keeps the key, anything
else (including nothing) lets it through to the terminal, then the held keys run
in order. The wait is a quarter of a second. A script that is busy or far away
and misses it keeps the key eaten, and its function still runs when it gets to
it. Named actions need no answer and always keep their key.

The script's host decides where the keys apply: a script on a peer binds keys on
every canvas attached to that peer, so one that runs on `enterprise` shapes the
keyboard of whoever is looking at it.

## Timers, commands, JSON

- `gct.sleep(s)`, `gct.after(s, fn)`, `gct.every(s, fn)`. A timer is
  `{cancel(), active()}`. Timers never run during other script code; ticks
  missed while busy are dropped, not replayed. At most 1,024 timers (past that
  the script exits 1). Timers made in a handler keep acting for that handler's
  pane.
- `gct.exec(argv[, opts])` runs a program with no shell and waits. Returns
  `{ok, code, signal, stdout, stderr, timed_out}`, or `nil, err` only if it
  never started; a non-zero exit is a result, so check `ok`. Options: `cwd`,
  `env` (`false` removes a variable), `clear_env`, `stdin`, `timeout` (SIGTERM,
  then SIGKILL after 2s), `stdout`/`stderr` (`false` discards).
- `gct.exec.start(argv[, opts])` returns a handle without waiting: `h:wait([s])`,
  `h:write(text)`, `h:close_stdin()`, `h:kill([signal])`, `h:running()`, `h.pid`.
  `stdout`/`stderr` may be callbacks, called per chunk (not per line). Children
  die with the script unless `detach = true`. `stdin = true` keeps input open.
- `gct.json.encode(v[, {indent=true}])` and `gct.json.decode(text)`; `null`
  becomes `nil`, and an empty table encodes as `{}`.
- `gct.action{name=, run=function(ctx, args) end}` defines a named function;
  `gct.invoke(name[, args])` runs it. Give it a `title` and it is also in the
  [command palette](#command-palette). `gct.log([level,] message)` prints to
  stderr.

## Autoload

Every `*.lua` in `~/.config/gct/autoload/` (or `$GCT_CONFIG_DIR/autoload/`) runs
whenever the daemon does, as its own `gctd lua` process. The folder is rescanned
every couple of seconds: add a file and it starts, save it and it restarts,
delete it and it stops. A script that fails is retried with a growing delay (up
to a minute); one that ends cleanly stays done until the file changes. Output
goes to `script-logs/<name>.lua.log` beside `state.json`. An autoloaded script
is not in a pane, so it has no `self`.

`require` finds Lua modules in `~/.config/gct/lua/` (`?.lua`).

```lua
-- ~/.config/gct/autoload/notify.lua: say when something running in a pane finishes.
gct.on("terminal.child_exited", function(ctx, ev)
  if ev.exit_code ~= 0 then
    gct.pane.notify{ pane = ev.pane_id, title = "failed", body = "exit " .. ev.exit_code }
  end
end)
```

## Command palette

`⌘⇧P` opens a palette of GCT's own actions and every script action that has a
`title`. Type to filter: each word has to fit the title, category, keywords or
description. `↑`/`↓` move, `⏎` runs, `esc` closes.

```lua
gct.action{
  name = "open_notes",
  title = "Notes: Open",
  description = "Open today's notes in a split",
  category = "Notes",
  keywords = "journal todo",         -- a string, or a list of words
  run = function(ctx, args)
    gct.pane.open{ cmd = "nvim ~/notes/today.md", side = "right" }
  end,
}
```

`description`, `category` and `keywords` only help you find it; the title is what
shows. An action without a `title` stays out of the palette: it is for
`gct.invoke` and key bindings. Redefining one replaces it.

A pick runs `run(ctx, args)` in the script that defined it, with `ctx.origin ==
"palette"` and `ctx.pane_id` the focused pane when it lives on the script's host.
`args` is an empty table: the palette has no way to ask for arguments, so an
action that needs one asks for it itself. The `args = { target = "string?" }` in
Rex's spec is accepted and ignored.

Entries live as long as their script: a plugin's actions are there while it
runs and go when it stops or its daemon's link does. They go out when the
script's first run ends, so a main chunk that sleeps for a while shows up late.
A script with nothing but titled actions stays up on its own. At most 1,024 per
script. The actions of every attached host's scripts are in the one palette.
Rebind it with `command-palette` under `[keybinds]`.

## Plugins

A plugin is a folder in `~/.config/gct/plugins/` (or `$GCT_CONFIG_DIR/plugins/`)
with an `init.lua`. It runs like an autoloaded script, as its own process, with
the same restart rules and a log in `script-logs/plugin-<name>.log`.

```
plugins/leaf/
├── init.lua       returns { setup = function(opts) ... end }
├── lua/           require("x") finds lua/x.lua, for this plugin only
└── plugin.toml    optional: version = "1.2.0", description = "..."
```

```lua
-- plugins/hello/init.lua
return {
  setup = function(opts)
    gct.on("terminal.bell", function(ctx)
      gct.pane.notify{ pane = ctx.pane_id, title = opts.title or "bell" }
    end)
  end,
}
```

`setup` gets the `[plugin.<name>]` table of `config.toml` (numbers and booleans
keep their type), and is also `gct.args`. Editing the table restarts the plugin;
`enabled = false` stops it. A file that returns nothing, or a table without
`setup`, simply runs.

```toml
[plugin.hello]
title = "ding"
```

`gctd plugin` installs them from git:

```sh
gctd plugin install owner/repo            # GitHub; or a git URL, or ./path
gctd plugin install owner/repo --ref v1.2 # a branch, tag or commit
gctd plugin list [--json]
gctd plugin update [name]                 # fetch, move to the ref's tip, re-pin
gctd plugin remove name
gctd plugin install                       # no argument: put back what plugins.lock names
```

`plugins.lock` (beside `config.toml`, safe to commit) records each plugin's
source, ref and exact commit, so a second machine gets the same code with
`gctd plugin install`. `update` moves a branch or the default branch to its tip
and leaves a tag or commit where it is. A folder you made yourself is listed as
`(local)` and `remove` won't delete it. A symlink into your own checkout works
too, and is the way to develop one: saving any file in it restarts the plugin.

A plugin runs with your permissions, `gct.exec` included. Read what you
install.

## Coming from Rex

- The namespace is `gct`, and GCT has panes where Rex has sessions, windows,
  blocks and layers. `block_id` is `pane_id`; `rex.session.*` calls become
  `gct.pane.*`. There are no `session_*`, `window_*` or `client_*` events, no
  `--all` or `-s`. `gct.host` exists but only checks out at load: hosts live in
  `[host.<name>]`.
- `rex.bind`, `rex.unbind`, `rex.mode`, `rex.bindings` and `rex.modes` are
  `gct.*` and take the same arguments. Rex only honors them in its config file,
  and in a script they do nothing; here a running script owns its keys, which
  go when it does. An action is one of GCT's own (`new-pane`, `fit-all`...), not
  Rex's (`pane.split`).
- Rex runs Lua 5.1, GCT 5.4: `setfenv` and `unpack` are gone. Load data-only
  files with `load(text, name, "t", {})`.
- `rex.action` is `gct.action`, and an action with a `title` is in the
  [command palette](#command-palette). A Rex plugin is a Lua file that calls
  `rex.action` from `init.lua`; here it is a [plugin](#plugins) folder whose
  `init.lua` returns `{ setup = function(opts) end }`, and runs as its own
  process, so a plugin can't see the others' actions or globals.
- `rex.block.call` is `gct.block.call`, with the differences in
  [Terminal methods](#terminal-methods); `rex.server` is `gct.server`, scoped
  to a peer's panes.

The event and timer scripts from the Awesome Rex list (rex-hatch's layout
builder, rexboard's observer, rexkit's watcher, and the examples in Rex's own
docs) run after changing `rex` to `gct` and replacing their calls to Rex's
sessions with `gct.pane.*` and `gct.layout.open`.
