-- The command palette against a real canvas: entries arrive, real keystrokes
-- open it and filter it, enter runs the pick in its script (and in the canvas,
-- for a built-in).
--   demo/launch.sh tokyo-night
--   swiftc -O scripts/post-key.swift -o /tmp/post-key
--   gctd lua scripts/lua-palette-e2e.lua pid=<canvas pid> post=/tmp/post-key
-- (the gctd of the demo: $HOME/Library/Application Support/GCT Demo/bin/gctd,
--  with GCT_SOCK pointing at its daemon.sock). Every line should say ok.
local pid, post = tostring(gct.args.pid), gct.args.post
assert(gct.args.pid and post, "pid= and post= are required")

-- US virtual keycodes.
local KEY = {
  a = 0, s = 1, d = 2, f = 3, h = 4, g = 5, z = 6, x = 7, c = 8, v = 9, b = 11,
  q = 12, w = 13, e = 14, r = 15, y = 16, t = 17, ["2"] = 19, o = 31, u = 32,
  i = 34, p = 35, l = 37, j = 38, k = 40, n = 45, m = 46,
  space = 49, enter = 36, escape = 53,
}

local ran = {}
local out = {}

local function press(code, ...)
  gct.exec({ post, pid, tostring(code), ... })
end

local function type_text(text)
  for ch in text:gmatch(".") do
    press(ch == " " and KEY.space or KEY[ch])
    gct.sleep(0.03)
  end
end

local function check(name, got, want)
  local ok = got == want
  out[#out + 1] = (ok and "ok   " or "FAIL ") .. name .. "  got " .. string.format("%q", tostring(got)) .. (ok and "" or (", want " .. string.format("%q", tostring(want))))
end

-- Events (a pick coming back) don't run while a timer callback does, so the
-- test is a chain of short steps: { seconds to wait first, what to do }.
local steps = {}
local function step(wait, fn) steps[#steps + 1] = { wait, fn } end

-- cmd+shift+p, a query, enter; esc after, in case nothing matched and it stayed open.
local function pick(query)
  step(0.2, function() press(KEY.p, "cmd", "shift") end)
  step(0.5, function() type_text(query) end)
  step(0.3, function() press(KEY.enter) end)
  step(0.8, function() press(KEY.escape) end)
  step(0.4, function() end)
end

local function run_steps()
  local i = 0
  local function nxt()
    i = i + 1
    local s = steps[i]
    if not s then return end

    gct.after(s[1], function() s[2](); nxt() end)
  end
  nxt()
end

gct.action{ name = "e2e_alpha", title = "E2E: Alpha", category = "E2E", description = "first",
  run = function(ctx, args) ran[#ran + 1] = "alpha:" .. tostring(ctx.origin) .. ":" .. type(args) end }
gct.action{ name = "e2e_beta", title = "E2E: Beta", category = "E2E", keywords = "zebra stripes",
  run = function(ctx, args) ran[#ran + 1] = "beta:" .. tostring(ctx.origin) .. ":" .. type(args) end }
-- No title: for gct.invoke and keys, not for the palette.
gct.action{ name = "e2e_hidden", run = function() ran[#ran + 1] = "hidden" end }

local typing, panes, before

-- The entries go out when this chunk returns; the steps start after.
step(1, function()
  typing = gct.pane.open{ name = "typing", cmd = "cat" }
end)
step(1, function() gct.pane.focus{ pane = typing.pane_id } end)
step(0.5, function() end)

pick("beta")
step(0, function() check("a typed name runs its entry, from the palette", table.concat(ran, ","), "beta:palette:table") end)

pick("zebra")
step(0, function() check("a keyword finds it", table.concat(ran, ","), "beta:palette:table,beta:palette:table") end)

pick("e2e alp")
step(0, function() check("every word fits, a prefix will do", ran[#ran], "alpha:palette:table") end)

step(0, function() before = #ran end)
pick("hidden")
step(0, function() check("an action with no title isn't listed", #ran, before) end)

step(0, function() panes = #gct.pane.list{}.panes end)
pick("new pane")
step(0.3, function() check("a built-in runs in the canvas", #gct.pane.list{}.panes, panes + 1) end)

step(0, function()
  print(table.concat(out, "\n"))
  gct.stop()
end)

run_steps()
