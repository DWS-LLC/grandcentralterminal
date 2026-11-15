-- Keys against a real canvas. Needs a canvas, so it is not in lua-smoke.sh:
--   demo/launch.sh tokyo-night
--   GCT_SOCK="$HOME/Library/Application Support/GCT Demo/daemon.sock" \
--     "$HOME/Library/Application Support/GCT Demo/bin/gctd" lua scripts/lua-keys-e2e.lua
-- Every line should start with "ok". It opens a few panes in that canvas.
local log = {}
local function note(s) log[#log + 1] = s end
local function settle(n)
  for _ = 1, 40 do
    if #log >= n then return end
    gct.sleep(0.05)
  end
end
local function panes() return #gct.pane.list{}.panes end

gct.action{ name = "seq_action", run = function(ctx, args) note("action:" .. tostring(args and args.n)) end }
gct.mode("nav", { exclusive = true })
gct.bind("ctrl+alt+m", "client.mode.enter", { name = "nav" })
gct.bind("nav/j", function(ctx, ev) note("nav-j:" .. ev.mode) end)
gct.bind("nav/g>g", "seq_action", { n = 7 })
gct.bind("ctrl+alt+q", function(ctx, ev) note("fn:" .. ev.keybinding .. ":" .. tostring(ev.prefix)) end)
gct.bind("ctrl+alt+w>c", function(ctx, ev) note("seq:" .. ev.keybinding .. ":" .. table.concat(ev.prefix, ",")) end)
gct.bind("ctrl+alt+n", "new-pane")
gct.sleep(0.5)

local out = {}
local function step(name, want)
  local got = table.concat(log, "|")
  out[#out + 1] = (got == want and "ok   " or "FAIL ") .. name .. "  " .. got .. (got == want and "" or ("  (want " .. want .. ")"))
  log = {}
end

gct.client.press("ctrl+alt+q"); settle(1); step("function", "fn:ctrl+alt+q:nil")
gct.client.press("ctrl+alt+w>c"); settle(1); step("sequence", "seq:c:ctrl+alt+w")
gct.client.press("ctrl+alt+x"); gct.sleep(0.3); step("unbound passes", "")

gct.client.press("ctrl+alt+m>j"); settle(1); step("mode key", "nav-j:nav")
gct.client.press("q"); gct.sleep(0.3); step("exclusive swallows", "")
gct.client.press("g>g"); settle(1); step("mode sequence + action args", "action:7")
gct.client.press("escape>j"); gct.sleep(0.4); step("escape leaves the mode", "")

local before = panes()
gct.client.press("ctrl+alt+n"); gct.sleep(0.8)
out[#out + 1] = (panes() == before + 1 and "ok   " or "FAIL ") .. "built-in action  " .. before .. "->" .. panes()

before = panes()
gct.client.press("cmd+t"); gct.sleep(0.8)
out[#out + 1] = (panes() == before + 1 and "ok   " or "FAIL ") .. "config default (cmd+t)  " .. before .. "->" .. panes()

gct.unbind("cmd+t")
gct.sleep(0.3)
before = panes()
gct.client.press("cmd+t"); gct.sleep(0.6)
out[#out + 1] = (panes() == before and "ok   " or "FAIL ") .. "unbind masks a default  " .. before .. "->" .. panes()

print(table.concat(out, "\n"))
gct.stop()
