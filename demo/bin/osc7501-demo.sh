#!/usr/bin/env bash
# OSC 7501 live demo: walks every program-status state so the pane
# titlebar dances. Run inside a GCT pane and watch its right side:
#   bash demo/bin/osc7501-demo.sh
# ~35s end to end. Type anything afterward to dismiss the done/error
# report (that's the "seen it" path).
set -u
st() { printf '\033]7501;%s\033\\' "$1"; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
say() { printf '→ %s\n' "$1"; }

say "working, indeterminate (spinner, app name)"
st "state=working:app=demo:msg=$(b64 'Resolving dependencies')"
sleep 3

say "working with progress 0→100"
for i in $(seq 0 5 100); do
    st "state=working:app=demo:progress=$i:msg=$(b64 'Building crates')"
    sleep 0.35
done

say "blocked: needs your permission"
st "state=blocked:kind=permission:app=demo:msg=$(b64 'Apply 3 to add, 1 to change, 0 to destroy?')"
sleep 4

say "back to working"
st "state=working:app=demo:msg=$(b64 'Applying changes')"
sleep 2

say "two workers: one pushing, one stuck on approval"
st "state=working:id=us-east:title=$(b64 'US East'):progress=40:msg=$(b64 'Pushing image')"
st "state=blocked:kind=permission:id=eu-west:title=$(b64 'EU West'):msg=$(b64 'Approve deploy to prod?')"
sleep 2
for i in 50 60 70 80 90 100; do
    st "state=working:id=us-east:title=$(b64 'US East'):progress=$i:msg=$(b64 'Pushing image')"
    sleep 0.5
done
say "us-east healthy (done survives, blocked still wins)"
st "state=done:id=us-east:title=$(b64 'US East'):msg=$(b64 'Healthy')"
sleep 4

say "all done"
st "state=clear:id=eu-west"
st "state=done:app=demo:msg=$(b64 'Deployed v2.4.1')"
sleep 3

say "and now it breaks"
st "state=error:app=demo:msg=$(b64 'Migration failed on step 7')"
sleep 4

say "type anything to dismiss done/error — or rerun $0"
st "state=clear"
st "state=idle:app=demo"
