-- Real keystrokes against a real canvas: held, answered, passed on, timed out.
--   demo/launch.sh tokyo-night
--   swiftc -O scripts/post-key.swift -o /tmp/post-key
--   gctd lua scripts/lua-keys-typed-e2e.lua pid=<canvas pid> post=/tmp/post-key
-- (the gctd of the demo: $HOME/Library/Application Support/GCT Demo/bin/gctd,
--  with GCT_SOCK pointing at its daemon.sock). Every line should say ok.
local pid, post = tostring(gct.args.pid), gct.args.post
assert(gct.args.pid and post, "pid= and post= are required")

-- US virtual keycodes.
local KEY = { a = 0, s = 1, h = 4, g = 5, z = 6, y = 16, b = 11 }
local log = {}
local out = {}

local typing = gct.pane.open{ name = "typing", cmd = "cat" }
gct.sleep(1)
gct.pane.focus{ pane = typing.pane_id }
gct.sleep(0.5)

local function shown() return gct.pane.dump{ pane = typing.pane_id, strip_ansi = true }.text end

-- What reached the terminal while these keys were typed and answered.
local function typed(keys, settle)
  local before = shown()
  for _, k in ipairs(keys) do
    gct.exec({ post, pid, tostring(KEY[k]) })
    gct.sleep(0.03)
  end
  gct.sleep(settle or 0.8)
  return shown():sub(#before + 1)
end

local function check(name, got, want)
  out[#out + 1] = (got == want and "ok   " or "FAIL ") .. name .. "  got " .. string.format("%q", got) .. (got == want and "" or (", want " .. string.format("%q", want)))
end

gct.bind("y", function() log[#log + 1] = "y" return true end)
gct.bind("z", function() log[#log + 1] = "z" end)
gct.bind("g>h", function() log[#log + 1] = "g>h" end)
gct.bind("s", function() gct.sleep(0.6) log[#log + 1] = "s" return false end)
gct.sleep(0.5)

check("true keeps the key", typed{ "y" }, "")
check("nothing returned lets it through", typed{ "z" }, "z")
check("a sequence passes only its last key", typed{ "g", "h" }, "h")
check("it ran each time", table.concat(log, ","), "y,z,g>h")

-- The script takes 0.6s: past the deadline the key stays eaten, and the keys
-- typed behind it wait, then arrive in order.
log = {}
check("slow answer: key eaten, followers in order", typed({ "s", "a", "b" }, 1.5), "ab")
check("the slow function still ran", table.concat(log, ","), "s")

-- A half-typed sequence is dropped after sequence-timeout (2s by default).
log = {}
gct.exec({ post, pid, tostring(KEY.g) })
gct.sleep(2.6)
check("a stale prefix is dropped", typed{ "h" }, "h")
check("so the sequence didn't complete", #log, 0)

print(table.concat(out, "\n"))
gct.pane.close{ pane = typing.pane_id }
gct.stop()
