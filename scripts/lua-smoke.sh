#!/usr/bin/env bash
# Integration smoke for `gctd lua`: a throwaway daemon, a battery of scripts.
# Needs `swift build --product gctd --product ptyexec` first.
#
#   scripts/lua-smoke.sh            run everything
#   BIN=.build/release scripts/lua-smoke.sh
#
# Own daemon, socket and state in a fresh mktemp dir; the live install is
# untouched. Pane names avoid hex (a, b, c would match uuid prefixes).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/.build/out/Products/Debug}"
D=$(mktemp -d)
# Unix socket paths cap at 104 bytes: cd in and use a relative one.
cd "$D" || exit 1
export GCT_HOME="$D" GCT_SOCK=s GCT_STATE="$D/state.json" GCT_PID="$D/pid" GCT_CONFIG_DIR="$D/cfg" GCT_PANE_ID=
mkdir -p cfg peer/cfg
# A peer for gct.server: a second daemon on a free TCP port, dialed from config.toml.
PEER_PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
printf '[host.bee]\nhost = "127.0.0.1"\nport = %s\ntoken = "tok"\n' "$PEER_PORT" > cfg/config.toml
( cd peer && GCT_HOME="$D/peer" GCT_SOCK=p GCT_STATE="$D/peer/state.json" GCT_PID="$D/peer/pid" \
  GCT_CONFIG_DIR="$D/peer/cfg" GCT_PORT="$PEER_PORT" GCT_TOKEN=tok "$BIN/gctd" >../peer.log 2>&1 & )
for _ in $(seq 100); do [ -S peer/p ] && break; sleep 0.05; done
( "$BIN/gctd" >daemon.log 2>&1 & )
for _ in $(seq 100); do [ -S s ] && break; sleep 0.05; done
[ -S s ] || { echo "daemon did not start"; cat daemon.log; exit 1; }

# The pid file, not $!: the daemon runs under a wrapper subshell.
stop_daemon() { kill "$(tr -dc 0-9 < pid)" 2>/dev/null; }
stop_peer() { kill "$(tr -dc 0-9 < peer/pid)" 2>/dev/null; }
trap 'stop_daemon; stop_peer' EXIT

G() { "$BIN/gctd" "$@"; }
pass=0
failed=0
check() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    return
  fi
  failed=$((failed + 1))
  printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"
}
# lua <name> <want stdout> <want status> <args...>
lua() {
  local name=$1 want=$2 rc=$3
  shift 3
  local out
  out=$(G lua "$@" 2>err.txt)
  local got=$?
  check "$name (stdout)" "$want" "$out"
  check "$name (status)" "$rc" "$got"
}

lua arithmetic 2 0 -e 'return 1+1'
lua args '{"n":3,"ok":true,"s":"hi"}' 0 -e 'return gct.args' n=3 ok=true s=hi
lua args-json '{"a":{"b":[1,2]}}' 0 -e 'return gct.args' --args '{"a":{"b":[1,2]}}'
echo 'return 40+2' | lua stdin 42 0 -
lua open-wait 7 0 -e 'local p=gct.pane.open{name="job",cmd="exit 7"}; return gct.pane.wait{pane=p.pane_id,timeout=10}.exit_code'
lua dump true 0 -e 'gct.pane.open{name="echoer",cmd="echo hello-lua; sleep 3"}; local found=false; for i=1,50 do if gct.pane.dump{pane="echoer",strip_ansi=true}.text:find("hello-lua",1,true) then found=true break end gct.sleep(0.1) end; gct.pane.close{pane="echoer"}; return found'

lua on-exit 'exit 3' 3 -e 'gct.on("terminal.child_exited", function(ctx, ev) print("exit "..ev.exit_code); gct.stop(ev.exit_code) end); gct.pane.open{name="ev5",cmd="exit 3"}'
lua wait-filter 5 0 -e 'local p=gct.pane.open{name="w6",cmd="sleep 0.3; exit 5"}; return gct.wait("terminal.child_exited",{pane_id=p.pane_id},10).exit_code'
lua wait-timeout '"timeout"' 0 -e 'local ev,err=gct.wait("never_fires",0.3); return err'
lua every-stop 'n=3' 0 -e 'local n=0; gct.every(0.05,function() n=n+1; if n==3 then print("n="..n); gct.stop(0) end end)'
lua after-stop tick 4 -e 'gct.after(0.1,function() print("tick"); gct.stop(4) end)'
lua timer-cancel '[false,true,true]' 0 -e 'local n=0; local t=gct.every(0.05,function() n=n+1 end); gct.sleep(0.2); t:cancel(); local m=n; gct.sleep(0.2); return {t:active(), n==m, m>=2}'

lua exec-out '"hi\n"' 0 -e 'return gct.exec({"echo","hi"}).stdout'
lua exec-fail '[3,false,"e\n"]' 0 -e 'local r=gct.exec({"sh","-c","echo e >&2; exit 3"}); return {r.code,r.ok,r.stderr}'
lua exec-timeout '[true,false]' 0 -e 'local r=gct.exec({"sleep","5"},{timeout=0.3}); return {r.timed_out,r.ok}'
lua exec-stdin '"piped"' 0 -e 'return gct.exec({"cat"},{stdin="piped"}).stdout'
lua exec-env '"bar\n"' 0 -e 'return gct.exec({"sh","-c","echo $FOO"},{env={FOO="bar"}}).stdout'
lua exec-missing '[true,"cannot run nonexistent-cmd-x: not found"]' 0 -e 'local r,err=gct.exec({"nonexistent-cmd-x"}); return {r==nil,err}'
lua exec-stream '[0,"a\nb\n"]' 0 -e 'local c={}; local h=gct.exec.start({"sh","-c","echo a; echo b"},{stdout=function(s) c[#c+1]=s end}); local r=h:wait(5); return {r.code,table.concat(c)}'

lua json-roundtrip '{"a":[1,2,3],"b":true,"c":"x"}' 0 -e 'return gct.json.decode(gct.json.encode({a={1,2,3},b=true,c="x"}))'
lua json-bad true 0 -e 'local v,err=gct.json.decode("{bad"); return err~=nil'
lua json-empty '"{}"' 0 -e 'return gct.json.encode({},{indent=true})'

lua err-nopane '"no such pane nope-nope"' 0 -e 'local ok,err=gct.pane.close{pane="nope-nope"}; return err'
lua err-raise '' 1 -e 'error("boom")'
check err-raise-msg true "$(grep -q boom err.txt && echo true || echo false)"
lua on-late "$(printf 'false\ttrue')" 0 -e 'gct.after(0.05,function() local ok,err=pcall(gct.on,"x",function() end); print(ok,err~=nil); gct.stop() end)'
lua popen-off '[false,true]' 0 -e 'local ok,err=pcall(io.popen,"ls"); return {ok,err~=nil}'
lua stop-pcall '' 5 -e 'pcall(gct.stop,5); print("unreachable")'
lua unknown-script '' 2 notascript

lua renamed after13 0 -e 'gct.on("pane_renamed",function(ctx,ev) print(ev.pane_name); gct.pane.close{pane=ev.pane_id}; gct.stop() end); local p=gct.pane.open{name="before13",cmd="sleep 5"}; gct.pane.rename{pane=p.pane_id,name="after13"}'
lua view-changed number 0 -e 'gct.on("view_changed",function(ctx,ev) print(type(ev.revision)); gct.stop() end); gct.pane.open{name="vc14",cmd="sleep 5"}'
lua group-created "$(printf 'g15\t2')" 0 -e 'gct.on("group_created",function(ctx,ev) print(ev.group_name,#ev.members); gct.stop() end); local a=gct.pane.open{name="ga",cmd="sleep 8"}; local b=gct.pane.open{name="gb",cmd="sleep 8"}; gct.group.create{panes={a.pane_id,b.pane_id},name="g15"}'
lua block-event child_exited 0 -e 'gct.on("block_event",function(ctx,ev) print(ev.name); gct.stop() end); gct.pane.open{name="be22",cmd="exit 0"}'
lua handler-error 'second ok' 0 -e 'local n=0; gct.on("pane_created",function() n=n+1; if n==1 then error("first") end; print("second ok"); gct.stop() end); gct.pane.open{name="he1",cmd="sleep 5"}; gct.pane.open{name="he2",cmd="sleep 5"}'
check handler-error-msg true "$(grep -q 'handler for pane_created' err.txt && echo true || echo false)"
lua fail-fast '' 1 --fail-fast -e 'gct.on("pane_created",function() error("first") end); gct.pane.open{name="ff1",cmd="sleep 5"}'
lua for-expiry '' 0 --for 1s -e 'gct.on("never_fires",function() end)'

lua kept-wait 9 0 -e 'local p=gct.pane.open{name="done30",cmd="exit 9",keep_open=true}; gct.sleep(0.5); local c=gct.pane.wait{pane=p.pane_id,timeout=5}.exit_code; gct.pane.close{pane=p.pane_id}; return c'
lua kept-once 1 0 -e 'local n=0; gct.on("terminal.child_exited",function() n=n+1 end); local p=gct.pane.open{name="k31",cmd="exit 2",keep_open=true}; gct.sleep(0.5); gct.pane.close{pane=p.pane_id}; gct.sleep(0.5); print(n); gct.stop()'
lua actions 5 0 -e 'gct.action{name="add",run=function(ctx,args) return args.a+args.b end}; return gct.invoke("add",{a=2,b=3})'

lua exec-discard '["",""]' 0 -e 'local r=gct.exec({"sh","-c","echo o; echo e >&2"},{stdout=false,stderr=false}); return {r.stdout,r.stderr}'
lua exec-handle '[true,"x\n"]' 0 -e 'local h=gct.exec.start({"cat"},{stdin=true}); h:write("x\n"); h:close_stdin(); local r=h:wait(5); return {r.ok,r.stdout}'
lua exec-kill '[false,"SIGTERM"]' 0 -e 'local h=gct.exec.start({"sleep","5"}); h:kill(); local r=h:wait(5); return {r.ok,r.signal}'
lua send true 0 -e 'local p=gct.pane.open{name="catp",cmd="cat"}; gct.pane.send{pane=p.pane_id,text="ping"}; local ok=false; for i=1,50 do if gct.pane.dump{pane=p.pane_id}.text:find("ping",1,true) then ok=true break end gct.sleep(0.1) end; gct.pane.close{pane=p.pane_id}; return ok'
lua canvas-verbs '[{},{},{}]' 0 -e 'return {gct.camera{zoom=1}, gct.font{delta=1}, gct.session{name="local"}}'
lua client-queue '{}' 0 -e 'return gct.client.queue("fit-all")'
lua session-unknown true 0 -e 'local ok,err=gct.session{name="nowhere"}; return err:find("no such session",1,true)~=nil'
# Far from every other test pane, so nothing is in the way below it.
G lua -e 'gct.pane.open{name="anchor",cmd="sleep 30",rect={x=100000,y=100000,w=400,h=300}}' > /dev/null
lua place-below '[true,true,true]' 0 --pane anchor -e 'local p=gct.pane.open{side="below",size="100%,50%",cmd="sleep 30"}; local a=gct.pane.inspect{pane="anchor"}.rect; local b=gct.pane.inspect{pane=p.pane_id}.rect; return {b.y+b.h==a.y,b.w==a.w,b.h==a.h/2}'
lua ctx-default '["anchor",true]' 0 --pane anchor -e 'return {gct.pane.inspect{}.name, gct.pane_id~=nil}'

# Canvas-only events: the canvas reports them, the daemon relays them to
# subscribers. gct.call stands in for the canvas here.
lua canvas-bell "$(printf 'bell\ttrue')" 0 -e 'local p; gct.on("terminal.bell",function(ctx,ev) print(ev.name, ev.pane_id==p.pane_id); gct.stop() end); p=gct.pane.open{name="bell1",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="terminal.bell"})'
lua canvas-title "$(printf 'hello\thello')" 0 -e 'local p; gct.on("terminal.title_changed",function(ctx,ev) print(ev.title, gct.pane.inspect{pane=p.pane_id}.title); gct.stop() end); p=gct.pane.open{name="title1",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="terminal.title_changed",title="hello"})'
lua canvas-notify "$(printf 'build done\tall green')" 0 -e 'local p; gct.on("terminal.desktop_notification",function(ctx,ev) print(ev.title, ev.body); gct.stop() end); p=gct.pane.open{name="note1",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="terminal.desktop_notification",title="build done",body="all green"})'
lua canvas-focus pane_focused 0 -e 'local p; gct.on("pane_focused",function(ctx,ev) print(ev.type); gct.stop() end); p=gct.pane.open{name="focus1",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="pane_focused"})'
lua canvas-catchall "$(printf 'bell')" 0 -e 'local p; gct.on("block_event",function(ctx,ev) print(ev.name); gct.stop() end); p=gct.pane.open{name="catch1",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="terminal.bell"})'
lua canvas-stale '"timeout"' 0 -e 'gct.call("reportEvent",{id="00000000-0000-0000-0000-000000000000",name="terminal.bell"}); local ev,err=gct.wait("terminal.bell",0.5); return err'

# Canvas events with a payload, faked the same way: progress, clipboard, program status.
lua canvas-progress "$(printf 'set\t42')" 0 -e 'local p; gct.on("terminal.progress_report",function(ctx,ev) print(ev.state, ev.progress); gct.stop() end); p=gct.pane.open{name="prog1",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="terminal.progress_report",payload=[[{"state":"set","progress":42}]]})'
lua canvas-clipboard "$(printf 'copied text\tcopied text')" 0 -e 'local p; gct.on("terminal.clipboard_written",function(ctx,ev) print(ev.text, ev.payload.text); gct.stop() end); p=gct.pane.open{name="clip1",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="terminal.clipboard_written",payload=[[{"text":"copied text"}]]})'
lua status-changed "$(printf 'build\tworking\treport')" 0 -e 'local p; gct.on("terminal.program_status_changed",function(ctx,ev) print(ev.id, ev.record.state, ev.reason); gct.stop() end); p=gct.pane.open{name="stat1",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="terminal.program_status_changed",payload=[[{"id":"build","record":{"id":"build","state":"working","progress":50},"reason":"report"}]]})'
lua status-removed "$(printf 'build\tclear')" 0 -e 'local p; gct.on("terminal.program_status_removed",function(ctx,ev) print(ev.ids[1], ev.reason); gct.stop() end); p=gct.pane.open{name="stat2",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="terminal.program_status_removed",payload=[[{"ids":["build"],"reason":"clear"}]]})'
lua status-catchall "$(printf 'program_status_changed')" 0 -e 'local p; gct.on("block_event",function(ctx,ev) print(ev.name); gct.stop() end); p=gct.pane.open{name="stat3",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="terminal.program_status_changed",payload=[[{"id":"","record":{"id":"","state":"idle"},"reason":"report"}]]})'

# block.call: Rex's terminal methods.
T='"com.superlogical.terminal"'
lua block-status '[1,"build","working",50]' 0 -e 'local p=gct.pane.open{name="blk1",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="terminal.program_status_changed",payload=[[{"id":"build","record":{"id":"build","state":"working","progress":50},"reason":"report"}]]}); local r=gct.block.call('"$T"',"program_status",{pane=p.pane_id}); return {#r.records, r.records[1].id, r.records[1].state, r.records[1].progress}'
lua block-status-gone 0 0 -e 'local p=gct.pane.open{name="blk2",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="terminal.program_status_changed",payload=[[{"id":"a","record":{"id":"a","state":"working"},"reason":"report"}]]}); gct.call("reportEvent",{id=p.pane_id,name="terminal.program_status_removed",payload=[[{"ids":["a"],"reason":"clear"}]]}); return #gct.block.call('"$T"',"program_status",{pane=p.pane_id}).records'
lua block-size '[80,24]' 0 -e 'local p=gct.pane.open{name="blk3",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="state.size",payload=[[{"cols":80,"rows":24}]]}); local r=gct.block.call('"$T"',"size",{pane=p.pane_id}); return {r.cols,r.rows}'
lua block-size-unknown '["nil","size is only known to the canvas, and it has not said"]' 0 -e 'local p=gct.pane.open{name="blk4",cmd="sleep 5"}; local r,err=gct.block.call('"$T"',"size",{pane=p.pane_id}); return {r==nil and "nil" or "set",err}'
lua block-title '"hello"' 0 -e 'local p=gct.pane.open{name="blk5",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="terminal.title_changed",title="hello"}); return gct.block.call('"$T"',"title",{pane=p.pane_id}).title'
lua block-pwd '"file:///usr"' 0 -e 'local p=gct.pane.open{name="blk6",cmd="sleep 5",cwd="/usr"}; return gct.block.call('"$T"',"pwd",{block_id=p.pane_id}).pwd'
lua block-process 'false' 0 -e 'local p=gct.pane.open{name="blk7",cmd="sleep 5"}; return gct.block.call('"$T"',"process",{pane=p.pane_id}).exited'
lua block-write '"typed-in"' 0 -e 'local p=gct.pane.open{name="blk8",cmd="cat"}; gct.block.call('"$T"',"write",{pane=p.pane_id,text="typed-in\n"}); local t=""; for i=1,50 do t=gct.block.call('"$T"',"format",{pane=p.pane_id}).text; if t:find("typed-in",1,true) then break end gct.sleep(0.1) end; gct.pane.close{pane=p.pane_id}; return t:match("typed%-in")'
lua block-format-vt '["vt",true]' 0 -e 'local p=gct.pane.open{name="blk9",cmd="printf \"\\033[31mred\\033[0m\"; sleep 5"}; local r; for i=1,50 do r=gct.block.call('"$T"',"format",{pane=p.pane_id,format="vt"}); if r.text:find("red",1,true) then break end gct.sleep(0.1) end; return {r.format, r.text:find("\27[31m",1,true)~=nil}'
lua block-format-html '[true,"html isn'"'"'t available; ask for text or vt"]' 0 -e 'local p=gct.pane.open{name="blk10",cmd="sleep 5"}; local r,err=gct.block.call('"$T"',"format",{pane=p.pane_id,format="html"}); return {r==nil,err}'
lua block-listdir '["/usr","bin"]' 0 -e 'local p=gct.pane.open{name="blk11",cmd="sleep 5",cwd="/usr"}; local r=gct.block.call('"$T"',"list_dir",{pane=p.pane_id}); return {r.path, r.dirs[1]}'
lua block-reset '{}' 0 -e 'local p=gct.pane.open{name="blk12",cmd="sleep 5"}; return gct.block.call('"$T"',"reset",{pane=p.pane_id})'
lua block-theme '{}' 0 -e 'local p=gct.pane.open{name="blk13",cmd="sleep 5"}; return gct.block.call('"$T"',"set_theme",{pane=p.pane_id,background="#102030",palette={"#000000","#ff0000"}})'
lua block-theme-bad '[true,"background is #rrggbb, got red"]' 0 -e 'local p=gct.pane.open{name="blk14",cmd="sleep 5"}; local r,err=gct.block.call('"$T"',"set_theme",{pane=p.pane_id,background="red"}); return {r==nil,err}'
lua block-resize-no true 0 -e 'local p=gct.pane.open{name="blk15",cmd="sleep 5"}; local r,err=gct.block.call('"$T"',"resize",{pane=p.pane_id,cols=100}); return r==nil and err~=nil'
lua block-bad-method true 0 -e 'local p=gct.pane.open{name="blk16",cmd="sleep 5"}; local r,err=gct.block.call('"$T"',"explode",{pane=p.pane_id}); return r==nil and err:find("has no method explode",1,true)~=nil'
lua block-bad-kind true 0 -e 'local p=gct.pane.open{name="blk17",cmd="sleep 5"}; local r,err=gct.block.call("com.example.other","title",{pane=p.pane_id}); return r==nil and err:find("no such block kind",1,true)~=nil'
lua block-context hello 0 -e 'gct.on("terminal.title_changed",function(ctx,ev) print(gct.block.call('"$T"',"title").title); gct.stop() end); local p=gct.pane.open{name="blk18",cmd="sleep 5"}; gct.call("reportEvent",{id=p.pane_id,name="terminal.title_changed",title="hello"})'

# servers: the peer is bee; an unknown label raises, and a server table stays on its host.
for _ in $(seq 100); do G hosts 2>/dev/null | grep -q 'bee.*up' && break; sleep 0.1; done
lua servers '[1,"bee",true]' 0 -e 'local ok,err=pcall(gct.server,"nowhere"); return {#gct.servers(), gct.servers()[1], not ok and err:find("no such server nowhere",1,true)~=nil}'
lua server-open '[1,0,true]' 0 -e 'local bee=gct.server("bee"); local r=bee.pane.open{name="onbee",cmd="sleep 30"}; local n=#bee.pane.list().panes; local mine=gct.pane.open{name="onhome",cmd="sleep 30"}; local _,err=bee.pane.inspect{pane=mine.pane_id}; local v=bee.view(); bee.pane.close{pane=r.pane_id}; gct.pane.close{pane=mine.pane_id}; return {n, #bee.pane.list().panes, err:find("is not on bee",1,true)~=nil}'
lua server-needs-pane '"pane is required on a server"' 0 -e 'local _,err=gct.server("bee").pane.inspect{}; return err'
lua server-block '[true,true]' 0 -e 'local bee=gct.server("bee"); local r=bee.pane.open{name="onbee2",cmd="sleep 30"}; local t=bee.block.call('"$T"',"title",{pane=r.pane_id}); local _,err=bee.block.call('"$T"',"list_dir",{pane=r.pane_id}); bee.pane.close{pane=r.pane_id}; return {t~=nil, err:find("runs on bee",1,true)~=nil}'
lua host-at-load '"ok"' 0 -e 'gct.host{label="x",endpoints={"a:1"}}; return "ok"'
lua host-later '[false,true]' 0 -e 'gct.after(0.05,function() local ok,err=pcall(gct.host,{label="x"}); print(gct.json.encode({ok, err:find("config file",1,true)~=nil})); gct.stop() end)'
lua call-unknown '"no such method nope"' 0 -e 'local ok,err=gct.call("nope"); return err'

lua layout '[3,true]' 0 -e 'local L=gct.layout; local r=gct.layout.open{layout=L.horizontal(0.4,L.block{command={"sleep","8"},label="lA"},L.vertical(0.5,L.block{command={"sleep","8"},label="lB"},L.block{command={"sleep","8"},label="lC"})),name="lay16"}; return {#r.pane_ids,r.group_id~=nil}'
G lua --json -e 'local o={}; for _,n in ipairs{"lA","lB","lC"} do local r=gct.pane.inspect{pane=n}.rect; o[#o+1]=n..":"..r.x..","..r.y..","..r.w.."x"..r.h end; return o' > layout.json
echo "layout rects: $(tr -d '\n ' < layout.json)"

# gct.bind / gct.mode: the script's side. No canvas here, so what the keys do
# is for the engine tests and the canvas run; this is the API they sit behind.
# A script with bindings stays up, so each body prints its answer and stops.
keys() {
  local name=$1 want=$2 body=$3
  lua "$name" "$want" 0 -e "local r = (function() $body end)(); print(gct.json.encode(r)); gct.stop()"
}
keys bind-actions '[{"action":"fit-all","key":"cmd+shift+d"},{"action":"zoom-pane","key":"ctrl+b>z"}]' 'gct.bind("Shift+Cmd+D","fit-all"); gct.bind("ctrl+b>z","zoom-pane"); local o={}; for _,b in ipairs(gct.bindings()) do o[#o+1]={key=b.key,action=b.action} end return o'
keys bind-fn '[true,"function"]' 'gct.bind("cmd+e",function() end); local b=gct.bindings{key="cmd+e"}[1]; return {b.action==nil, type(b.fn)}'
keys bind-source true 'gct.bind("cmd+d","fit-all"); return gct.bindings()[1].source:find("^%S+:%d+$")~=nil'
keys bind-filter '[1,1,0]' 'gct.bind("a","x1"); gct.bind("m1/b","x2"); return {#gct.bindings{mode="m1"}, #gct.bindings{action="x1"}, #gct.bindings{key="zzz"}}'
keys bind-mode-key '"resize left"' 'gct.bind("resize/Left","grow-window-left"); local b=gct.bindings()[1]; return b.mode .. " " .. b.key'
keys bind-slash-key '"none cmd+/"' 'gct.bind("cmd+/","fit-all"); local b=gct.bindings()[1]; return (b.mode or "none") .. " " .. b.key'
keys bind-fn-in-mode '[false,true]' 'local ok,err=pcall(gct.bind,"m/a",function() end); return {ok, err:find("gct.action",1,true)~=nil}'
keys bind-action-in-mode 1 'gct.action{name="act",run=function() end}; gct.bind("m/a","act"); return #gct.bindings()'
keys bind-bad-key false 'return (pcall(gct.bind,"hyper+x","fit-all"))'
keys bind-bad-seq false 'return (pcall(gct.bind,"ctrl+b>","fit-all"))'
keys bind-table-key '[false,true]' 'local ok,err=pcall(gct.bind,{},"fit-all"); return {ok, err:find("expected a string",1,true)~=nil}'
keys bind-enter-needs-name false 'return (pcall(gct.bind,"cmd+r","client.mode.enter"))'
keys bind-enter-ok 1 'gct.bind("cmd+r","client.mode.enter",{name="resize"}); return #gct.bindings()'
keys bind-enter-bad-mode false 'return (pcall(gct.bind,"cmd+r","client.mode.enter",{name="Bad Mode"}))'
keys unbind-count 2 'gct.bind("a","x"); gct.bind("a","y"); gct.bind("b","z"); return gct.unbind("a")'
keys unbind-target '[1,1]' 'gct.bind("a","x"); gct.bind("a","y"); local n=gct.unbind("a","x"); return {n, #gct.bindings()}'
keys unbind-fn '[1,1]' 'local f=function() end; gct.bind("a",f); gct.bind("a",function() end); local n=gct.unbind("a",f); return {n, #gct.bindings()}'
keys unbind-none 0 'return gct.unbind("q")'
keys unbind-binding '[1,1]' 'gct.bind("a","x"); gct.bind("b","y"); local n=gct.unbind(gct.bindings()[1]); return {n, #gct.bindings()}'
keys unbind-binding-fn '[1,0]' 'gct.bind("a",function() end); local n=gct.unbind(gct.bindings()[1]); return {n, #gct.bindings()}'
keys unbind-mode '[0,0]' 'gct.mode("m",{exclusive=true}); gct.bind("m/a","x"); gct.bind("m/b","y"); gct.unbind{mode="m"}; return {#gct.bindings(), #gct.modes()}'
keys unbind-bad false 'return (pcall(gct.unbind,"hyper+x"))'
keys mode-declared '"resize true"' 'gct.mode("resize",{exclusive=true}); local m=gct.modes()[1]; return m.name .. " " .. tostring(m.exclusive)'
keys mode-by-bind '"nav false"' 'gct.bind("nav/j","x"); local m=gct.modes()[1]; return m.name .. " " .. tostring(m.exclusive)'
keys mode-default-open false 'gct.mode("m"); return gct.modes()[1].exclusive'
keys mode-bad-option false 'return (pcall(gct.mode,"m",{loud=true}))'
keys mode-bad-name false 'return (pcall(gct.mode,"Not Ok"))'
keys mode-bad-exclusive false 'return (pcall(gct.mode,"m",{exclusive="yes"}))'
keys bind-args '{"dir":"right"}' 'gct.bind("cmd+d","pane_split",{dir="right"}); return gct.bindings()[1].args'
keys bind-order '["a","b","c"]' 'gct.bind("a","x"); gct.bind("b","x"); gct.bind("c","x"); local o={}; for _,b in ipairs(gct.bindings()) do o[#o+1]=b.key end return o'

# A script with only key bindings stays up; one without exits at once.
secs=$SECONDS
G lua --for 2s -e 'gct.bind("cmd+d","fit-all")' >/dev/null 2>&1
check keys-keep-alive true "$([ $((SECONDS - secs)) -ge 1 ] && echo true || echo false)"
secs=$SECONDS
G lua -e 'gct.bind("cmd+d","fit-all"); gct.unbind("cmd+d")' >/dev/null 2>&1
check keys-none-exits true "$([ $((SECONDS - secs)) -lt 2 ] && echo true || echo false)"

# Inside a pane the script acts for that pane.
G lua -e 'local p=gct.pane.open{name="selfp",cmd="\"'"$BIN"'/gctd\" lua -e \"return gct.pane_id\" > selfout.txt"}; gct.pane.wait{pane=p.pane_id,timeout=10}; return p.pane_id' > selfid.txt
check self-pane "$(tr -d '\n' < selfid.txt)" "$(tr -d '\n' < selfout.txt)"

# Autoload: ~/.config/gct/autoload/*.lua start with the daemon, restart when
# saved, stop when deleted, retry when they crash.
wait_for() { for _ in $(seq 120); do eval "$1" && return 0; sleep 0.1; done; return 1; }
mkdir -p cfg/autoload
cat > cfg/autoload/mark.lua <<'LUA'
local f = io.open("autoload-ran.txt", "a"); f:write("v1\n"); f:close()
gct.on("pane_created", function()
  local g = io.open("autoload-events.txt", "a"); g:write("created\n"); g:close()
end)
LUA
echo 'error("nope")' > cfg/autoload/crash.lua
wait_for '[ -f autoload-ran.txt ]'
check autoload-start v1 "$(head -1 autoload-ran.txt 2>/dev/null)"
G lua -e 'gct.pane.open{name="al1",cmd="exit 0"}'
wait_for 'grep -q created autoload-events.txt 2>/dev/null'
check autoload-events created "$(head -1 autoload-events.txt 2>/dev/null)"
wait_for 'grep -q nope script-logs/crash.lua.log 2>/dev/null'
check autoload-crash-log true "$(grep -q nope script-logs/crash.lua.log 2>/dev/null && echo true || echo false)"
sleep 1
sed -i.bak 's/v1/v2/' cfg/autoload/mark.lua
wait_for 'grep -q v2 autoload-ran.txt'
check autoload-restart true "$(grep -q v2 autoload-ran.txt && echo true || echo false)"
/bin/rm -f cfg/autoload/mark.lua cfg/autoload/crash.lua
wait_for '! pgrep -f "autoload/mark.lua" >/dev/null'
check autoload-stop true "$(pgrep -f 'autoload/mark.lua' >/dev/null && echo false || echo true)"

# Plugins: plugins/<name>/init.lua, installed from git, options from config.toml.
SRC="$D/plugsrc"
mkdir -p "$SRC/lua"
cat > "$SRC/init.lua" <<'LUA'
local helper = require("helper")
return { setup = function(opts)
  local f = io.open("plugin-ran.txt", "a")
  f:write(tostring(opts.msg), " ", tostring(opts.n), " ", helper.tag, " v1\n")
  f:close()
  -- A handler keeps the plugin running, so stopping it is something to see.
  gct.on("never_fires", function() end)
end }
LUA
echo 'return { tag = "helper-ok" }' > "$SRC/lua/helper.lua"
printf 'version = "1.0.0"\ndescription = "smoke"\n' > "$SRC/plugin.toml"
GIT() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
GIT init -q && GIT add -A && GIT commit -qm v1
printf '\n[plugin.plugsrc]\nmsg = "hello"\nn = 3\n' >> cfg/config.toml
plugin_up() { grep -q "$1" plugin-ran.txt 2>/dev/null && echo true || echo false; }

out=$(G plugin install "$SRC" 2>&1)
check plugin-install-status 0 "$?"
check plugin-install-out true "$(echo "$out" | grep -q '^installed plugsrc' && echo true || echo false)"
wait_for 'grep -q "hello 3 helper-ok v1" plugin-ran.txt 2>/dev/null'
check plugin-runs true "$(plugin_up 'hello 3 helper-ok v1')"
check plugin-list "plugsrc 1.0.0 managed" "$(G plugin list --json | python3 -c 'import json,sys; p=json.load(sys.stdin)["plugins"][0]; print(p["name"], p["version"], "managed" if p["managed"] else "hand")')"

# Options edited: a fresh start with the new values.
sed -i.bak 's/msg = "hello"/msg = "again"/' cfg/config.toml
wait_for 'grep -q "again 3" plugin-ran.txt 2>/dev/null'
check plugin-opts-restart true "$(plugin_up 'again 3 helper-ok v1')"

# Update: a new commit upstream lands, re-pins, and restarts the plugin.
sed -i.bak 's/ v1/ v2/' "$SRC/init.lua"
GIT add init.lua && GIT commit -qm v2
out=$(G plugin update 2>&1)
check plugin-update-status 0 "$?"
check plugin-update-out true "$(echo "$out" | grep -q '^plugsrc  .* -> ' && echo true || echo false)"
wait_for 'grep -q "again 3 helper-ok v2" plugin-ran.txt 2>/dev/null'
check plugin-update-runs true "$(plugin_up 'again 3 helper-ok v2')"
check plugin-update-pin "$(GIT rev-parse HEAD)" "$(python3 -c 'import json; print(json.load(open("cfg/plugins.lock"))["plugins"]["plugsrc"]["commit"])')"
out=$(G plugin update plugsrc 2>&1)
check plugin-update-same true "$(echo "$out" | grep -q 'up to date' && echo true || echo false)"

# enabled = false stops it; taking the line out starts it again.
runs=$(wc -l < plugin-ran.txt)
check plugin-stays-up true "$(pgrep -f 'plugin plugsrc' >/dev/null && echo true || echo false)"
printf 'enabled = false\n' >> cfg/config.toml
wait_for '! pgrep -f "plugin plugsrc" >/dev/null'
check plugin-disabled true "$(pgrep -f 'plugin plugsrc' >/dev/null && echo false || echo true)"
sed -i.bak '/^enabled/d' cfg/config.toml
wait_for "[ \$(wc -l < plugin-ran.txt) -gt $runs ]"
check plugin-reenabled true "$([ "$(wc -l < plugin-ran.txt)" -gt "$runs" ] && echo true || echo false)"

# Remove: folder, pin and process go; the lock keeps nothing.
G plugin remove plugsrc >/dev/null 2>&1
check plugin-remove-status 0 "$?"
check plugin-remove-folder true "$([ ! -e cfg/plugins/plugsrc ] && echo true || echo false)"
check plugin-remove-pin 0 "$(grep -c plugsrc cfg/plugins.lock)"
wait_for '! pgrep -f "plugin plugsrc" >/dev/null'
check plugin-remove-stops true "$(pgrep -f 'plugin plugsrc' >/dev/null && echo false || echo true)"

# Restore: the lock names a plugin whose folder is gone.
G plugin install "$SRC" >/dev/null 2>&1
/bin/rm -rf "$D/cfg/plugins/plugsrc"
out=$(G plugin install 2>&1)
check plugin-restore-out "restored plugsrc" "$out"
check plugin-restore-v2 true "$(grep -q ' v2' cfg/plugins/plugsrc/init.lua && echo true || echo false)"
G plugin remove plugsrc >/dev/null 2>&1

# A symlinked folder is a plugin too, and saving a file in it restarts it.
ln -s "$SRC" cfg/plugins/linked
wait_for 'grep -q "nil nil helper-ok" plugin-ran.txt 2>/dev/null'
check plugin-symlink-runs true "$(plugin_up 'nil nil helper-ok')"
runs=$(grep -c 'nil nil' plugin-ran.txt)
touch "$SRC/lua/helper.lua"
wait_for "[ \$(grep -c 'nil nil' plugin-ran.txt) -gt $runs ]"
check plugin-symlink-restart true "$([ "$(grep -c 'nil nil' plugin-ran.txt)" -gt "$runs" ] && echo true || echo false)"
/bin/rm -f cfg/plugins/linked

# Refusals: no init.lua, bad names, plugins you made by hand, unknown ones.
mkdir -p "$D/emptysrc"
git -C "$D/emptysrc" init -q
echo x > "$D/emptysrc/readme"
git -C "$D/emptysrc" add -A
git -C "$D/emptysrc" -c user.name=t -c user.email=t@t commit -qm x
G plugin install "$D/emptysrc" >/dev/null 2>&1
check plugin-no-init 1 "$?"
check plugin-no-leftovers 0 "$(ls -A cfg/plugins | grep -c .)"
G plugin install "$SRC" --name ../evil >/dev/null 2>&1
check plugin-bad-name 1 "$?"
G plugin install "$SRC" --ref --upload-pack=x >/dev/null 2>&1
check plugin-bad-ref 1 "$?"
G plugin remove nope >/dev/null 2>&1
check plugin-remove-unknown 3 "$?"
mkdir -p cfg/plugins/handmade
echo 'return {}' > cfg/plugins/handmade/init.lua
G plugin remove handmade >/dev/null 2>&1
check plugin-remove-by-hand 3 "$?"
check plugin-by-hand-kept true "$([ -f cfg/plugins/handmade/init.lua ] && echo true || echo false)"
check plugin-list-local true "$(G plugin list | grep -q '^handmade .*(local)' && echo true || echo false)"
G lua --plugin nosuch >/dev/null 2>&1
check plugin-run-unknown 3 "$?"
/bin/rm -rf "$D/cfg/plugins/handmade"

# Palette: a titled action keeps its script up, an untitled one is for invoke.
secs=$SECONDS
G lua --for 2s -e 'gct.action{name="pal", title="Pal", run=function() end}' >/dev/null 2>&1
check palette-keep-alive true "$([ $((SECONDS - secs)) -ge 1 ] && echo true || echo false)"
secs=$SECONDS
G lua -e 'gct.action{name="quiet", run=function() end}' >/dev/null 2>&1
check palette-untitled-exits true "$([ $((SECONDS - secs)) -lt 2 ] && echo true || echo false)"
lua palette-cap true 0 -e 'local ok, err = pcall(function() for i = 1, 1025 do gct.action{name = "a" .. i, title = "t", run = function() end} end end); print(tostring(err):find("at most 1024", 1, true) ~= nil); gct.stop(0)'
# An args spec is checked when the action is defined: a table of name = "type".
lua palette-args-spec '[false,false,true,true]' 0 -e 'local f = function() end; local a = pcall(gct.action, {name = "b1", title = "B", args = 5, run = f}); local b = pcall(gct.action, {name = "b2", title = "B", args = {n = 5}, run = f}); local c = pcall(gct.action, {name = "b3", title = "B", args = {n = "integer", note = "string?", odd = "mystery"}, run = f}); local d = pcall(gct.action, {name = "b4", args = 5, run = f}); print(gct.json.encode({a, b, c, d})); gct.stop(0)'
lua palette-redefine '"ran"' 0 -e 'gct.action{name="x", title="X", run=function() return "old" end}; gct.action{name="x", run=function() return "ran" end}; local r = gct.invoke("x"); print(gct.json.encode(r)); gct.stop(0)'

# Last: the daemon dies under a running script.
G lua --for 30s -e 'gct.on("never_fires",function() end)' 2>err.txt &
script=$!
sleep 0.5
stop_daemon
wait "$script"
check daemon-gone 4 "$?"

echo "pass=$pass fail=$failed"
[ "$failed" -eq 0 ]
