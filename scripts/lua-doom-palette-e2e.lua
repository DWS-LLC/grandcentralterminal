-- The palette must still have the keyboard after the doom hotkey hides GCT and
-- brings it back (you leave to copy something, you come back to type).
--   demo/launch.sh tokyo-night            (doom on ctrl+alt+space in its config)
--   swiftc -O scripts/post-key.swift -o /tmp/post-key
--   swiftc -O scripts/hotkey.swift -o /tmp/hotkey
--   gctd lua scripts/lua-doom-palette-e2e.lua pid=<canvas pid> post=/tmp/post-key hotkey=/tmp/hotkey
-- (the gctd of the demo, GCT_SOCK at its daemon.sock). Every line should say ok.
local pid, post, hotkey = tostring(gct.args.pid), gct.args.post, gct.args.hotkey
assert(gct.args.pid and post and hotkey, "pid=, post= and hotkey= are required")

-- US virtual keycodes.
local KEY = { b = 11, e = 14, t = 17, a = 0, p = 35, space = 49, enter = 36, escape = 53 }
local DOOM = { KEY.space, "ctrl", "alt" }

local ran, out, steps = {}, {}, {}

local function press(code, ...) gct.exec({ post, pid, tostring(code), ... }) end
local function type_text(text)
  for ch in text:gmatch(".") do press(KEY[ch]); gct.sleep(0.03) end
end
local function doom() gct.exec({ hotkey, "press", tostring(DOOM[1]), table.unpack(DOOM, 2) }) end
local function shown() return gct.exec({ hotkey, "visible", pid }).stdout:match("%d") == "1" end
local function step(wait, fn) steps[#steps + 1] = { wait, fn } end
local function check(name, got, want)
  local ok = got == want
  out[#out + 1] = (ok and "ok   " or "FAIL ") .. name .. "  got " .. tostring(got) .. (ok and "" or (", want " .. tostring(want)))
end

gct.action{ name = "doom_beta", title = "Doom: Beta", category = "Doom",
  run = function(ctx) ran[#ran + 1] = "beta:" .. tostring(ctx.origin) end }

-- Make sure the first press shows GCT, whatever state the last run left it in.
step(1, function() if not shown() then doom() end end)
step(1, function() check("GCT is on screen to begin with", shown(), true) end)

step(0.3, function() press(KEY.p, "cmd", "shift") end)       -- open the palette
step(0.6, function() type_text("be") end)                     -- half a query, still typing
step(0.3, function() doom() end)                              -- the hotkey hides GCT
step(1.2, function() check("the hotkey hid GCT", shown(), false) end)
step(0.3, function() doom() end)                              -- and brings it back
step(1.2, function() check("the hotkey brought GCT back", shown(), true) end)

step(0.3, function() type_text("ta") end)                     -- the query goes on where it was left
step(0.4, function() press(KEY.enter) end)
step(1, function()
  check("the palette kept the keyboard: the rest of the query and enter ran Beta",
    table.concat(ran, ","), "beta:palette")
end)

step(0, function()
  print(table.concat(out, "\n"))
  gct.stop()
end)

local i = 0
local function nxt()
  i = i + 1
  local s = steps[i]
  if not s then return end
  gct.after(s[1], function() s[2](); nxt() end)
end
nxt()
