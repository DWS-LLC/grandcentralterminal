-- Clicks and the palette: a click inside keeps it (and the keyboard in its
-- field), a click outside closes it, as esc does.
--   demo/launch.sh tokyo-night
--   swiftc -O scripts/post-key.swift -o /tmp/post-key
--   swiftc -O scripts/hotkey.swift -o /tmp/hotkey
--   gctd lua scripts/lua-palette-click-e2e.lua pid=<canvas pid> post=/tmp/post-key hotkey=/tmp/hotkey
-- (the gctd of the demo, GCT_SOCK at its daemon.sock). Every line should say ok.
local pid, post, hotkey = tostring(gct.args.pid), gct.args.post, gct.args.hotkey
assert(gct.args.pid and post and hotkey, "pid=, post= and hotkey= are required")

-- US virtual keycodes.
local KEY = { b = 11, e = 14, t = 17, a = 0, p = 35, enter = 36, escape = 53 }

local ran, out, steps = {}, {}, {}
local win = {}

local function press(code, ...) gct.exec({ post, pid, tostring(code), ... }) end
local function type_text(text)
  for ch in text:gmatch(".") do press(KEY[ch]); gct.sleep(0.03) end
end
local function click(x, y) gct.exec({ hotkey, "click", tostring(x), tostring(y) }) end
local function step(wait, fn) steps[#steps + 1] = { wait, fn } end
local function check(name, got, want)
  local ok = got == want
  out[#out + 1] = (ok and "ok   " or "FAIL ") .. name .. "  got " .. tostring(got) .. (ok and "" or (", want " .. tostring(want)))
end

gct.action{ name = "click_beta", title = "Click: Beta", category = "Click",
  run = function(ctx) ran[#ran + 1] = "beta" end }

step(1, function()
  local x, y, w, h = gct.exec({ hotkey, "bounds", pid }).stdout:match("(%d+) (%d+) (%d+) (%d+)")
  win = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
  assert(win.w, "no window on screen")
end)

-- Inside: the middle of the window is the middle of the palette.
step(0.3, function() press(KEY.p, "cmd", "shift") end)
step(0.6, function() click(win.x + win.w // 2, win.y + win.h // 2) end)
step(0.5, function() type_text("beta") end)
step(0.4, function() press(KEY.enter) end)
step(0.8, function() check("a click inside keeps the palette and its keyboard", table.concat(ran, ","), "beta") end)

-- Outside: the corner of the window is no part of it.
step(0.3, function() press(KEY.p, "cmd", "shift") end)
step(0.6, function() click(win.x + 12, win.y + 12) end)
step(0.6, function() type_text("beta") end)
step(0.4, function() press(KEY.enter) end)
step(0.8, function() check("a click outside closes it", table.concat(ran, ","), "beta") end)

-- And it opens again after that.
step(0.3, function() press(KEY.p, "cmd", "shift") end)
step(0.6, function() type_text("beta") end)
step(0.4, function() press(KEY.enter) end)
step(0.8, function() check("it opens again", table.concat(ran, ","), "beta,beta") end)

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
