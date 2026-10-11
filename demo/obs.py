"""OBS remote for the GCT shoot, over obs-websocket.

    obs.py setup              profile + scene: native display capture, 60fps
    obs.py rec start|stop     record (stop prints the file path)
    obs.py shot <file.png>    full-res still of the display source
    obs.py cursor on|off      show the pointer (manual shots) or not

Run with the demo venv: "$DEMO_HOME/venv/bin/python" -I demo/obs.py ...
The websocket password is read from OBS's own config, never printed.
"""

import configparser
import json
import pathlib
import re
import subprocess
import sys
import time

import obsws_python as obs

WS_CONFIG = pathlib.Path.home() / (
    "Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json")
PROFILE = "GCT Reel"
COLLECTION = "GCT Reel"
SCENE = "Screen"
SOURCE = "Display"
CAPTURE_KIND = "screen_capture"   # ScreenCaptureKit
DISPLAY_TYPE = 0                  # 0 = whole display
FPS = 60
HEVC = "com.apple.videotoolbox.videoencoder.ave.hevc"
# Constant quality, 1s GOP: screen content is mostly static, but camera
# glides need headroom or text smears mid-move.
HEVC_SETTINGS = {"rate_control": "CRF", "quality": 85, "keyint_sec": 1,
                 "profile": "main", "bframes": False}
RAW_DIR = pathlib.Path.home() / "Movies/GCT Reel/raw"
OBS_PROFILES = pathlib.Path.home() / "Library/Application Support/obs-studio/basic/profiles"


def client() -> obs.ReqClient:
    cfg = json.loads(WS_CONFIG.read_text())
    return obs.ReqClient(host="localhost", port=cfg["server_port"],
                         password=cfg["server_password"], timeout=10)


def swift_eval(src: str) -> str:
    return subprocess.run(["swift", "-e", src], capture_output=True,
                          text=True, check=True).stdout.strip()


def native_size() -> tuple[int, int]:
    # Backing pixels of the main screen. Scaled modes ("more space") render
    # above panel res, e.g. 3200x1800pt @2x = 6400x3600 on a 5K XDR.
    out = swift_eval("import AppKit\nlet s = NSScreen.main!\n"
                     "let k = s.backingScaleFactor\n"
                     "print(Int(s.frame.width * k), Int(s.frame.height * k))")
    w, h = out.split()
    return int(w), int(h)


def display_uuid() -> str:
    # Main display's CoreGraphics uuid, the id ScreenCaptureKit targets.
    return swift_eval("import ColorSync\nimport CoreGraphics\n"
                      "let u = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())!"
                      ".takeRetainedValue()\nprint(CFUUIDCreateString(nil, u)!)")


def write_profile_ini(w: int, h: int) -> None:
    # obs-websocket caps the canvas at 4096 wide, so 5K goes straight into
    # the profile ini (OBS honors it on load). Profile must be inactive.
    ini = OBS_PROFILES / PROFILE.replace(" ", "_") / "basic.ini"
    cfg = configparser.RawConfigParser()
    cfg.optionxform = str
    cfg.read(ini)
    sections = {
        "General": {"Name": PROFILE},
        "Video": {"BaseCX": w, "BaseCY": h, "OutputCX": w, "OutputCY": h,
                  "FPSType": 1, "FPSInt": FPS, "ScaleType": "lanczos"},
        "Output": {"Mode": "Advanced"},
        "AdvOut": {"RecType": "Standard", "RecFilePath": RAW_DIR,
                   "RecFormat2": "mov", "RecEncoder": HEVC, "RecTracks": 1},
    }
    for name, kv in sections.items():
        if not cfg.has_section(name):
            cfg.add_section(name)
        for k, v in kv.items():
            cfg.set(name, k, str(v))
    with ini.open("w") as f:
        cfg.write(f, space_around_delimiters=False)
    (ini.parent / "recordEncoder.json").write_text(json.dumps(HEVC_SETTINGS))


def ensure_profile(c: obs.ReqClient, w: int, h: int) -> None:
    # Park on another profile, rewrite ours, switch back to load it.
    profiles = c.get_profile_list()
    if PROFILE not in profiles.profiles:
        c.create_profile(PROFILE)   # also switches to it
    parking = next(p for p in profiles.profiles if p != PROFILE)
    c.set_current_profile(parking)
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    write_profile_ini(w, h)
    c.set_current_profile(PROFILE)


def ensure_scene(c: obs.ReqClient) -> None:
    # Scene collection with one full-display capture, cursor on.
    cols = c.get_scene_collection_list()
    if COLLECTION not in cols.scene_collections:
        c.create_scene_collection(COLLECTION)   # also switches to it
    elif cols.current_scene_collection_name != COLLECTION:
        c.set_current_scene_collection(COLLECTION)

    scenes = [s["sceneName"] for s in c.get_scene_list().scenes]
    if SCENE not in scenes:
        c.create_scene(SCENE)
    c.set_current_program_scene(SCENE)

    # Explicit display uuid: OBS's default target id 0 captures nothing,
    # and enumerating the uuid list over the websocket crashes OBS 32.
    settings = {"type": DISPLAY_TYPE, "show_cursor": False,
                "display_uuid": display_uuid()}
    inputs = [i["inputName"] for i in c.get_input_list().inputs]
    if SOURCE in inputs:
        c.set_input_settings(SOURCE, settings, True)
    else:
        c.create_input(SCENE, SOURCE, CAPTURE_KIND, settings, True)
    fit_item(c)


def fit_item(c: obs.ReqClient) -> None:
    # Pin the capture to the canvas. OBS keeps the item's old scale when the
    # canvas changes size (a 5120 -> 6400 switch left it at 1.25x, silently
    # cropping every recording to the top-left 80%).
    w, h = native_size()
    item = c.get_scene_item_id(SCENE, SOURCE).scene_item_id
    c.set_scene_item_transform(SCENE, item, {
        "positionX": 0, "positionY": 0, "rotation": 0,
        "scaleX": 1.0, "scaleY": 1.0, "alignment": 5,
        "boundsType": "OBS_BOUNDS_SCALE_INNER", "boundsAlignment": 0,
        "boundsWidth": w, "boundsHeight": h,
        "cropLeft": 0, "cropRight": 0, "cropTop": 0, "cropBottom": 0})


def setup() -> None:
    c = client()
    w, h = native_size()
    ensure_profile(c, w, h)
    ensure_scene(c)
    print(f"obs ready: {w}x{h}@{FPS} -> {RAW_DIR}")


def rec(cmd: str) -> None:
    c = client()
    if cmd == "start":
        c.start_record()
        return
    path = c.stop_record().output_path
    # StopRecord returns before the muxer writes the moov atom.
    while c.get_record_status().output_active:
        time.sleep(0.2)
    time.sleep(1.0)
    print(path)


def shot(path: str) -> None:
    # Screenshot at the source's native size (5K); absolute path required.
    out = pathlib.Path(path).expanduser().resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    # No width/height: the API caps them at 4096; omitted = source size.
    client().send("SaveSourceScreenshot", {
        "sourceName": SOURCE, "imageFormat": "png", "imageFilePath": str(out)})
    print(out)


def cursor(state: str) -> None:
    client().set_input_settings(SOURCE, {"show_cursor": state == "on"}, True)


def main() -> None:
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    if args[0] == "setup":
        setup()
        return
    if args[0] == "rec" and len(args) == 2:
        rec(args[1])
        return
    if args[0] == "cursor" and len(args) == 2:
        cursor(args[1])
        return
    if args[0] == "shot" and len(args) == 2:
        shot(args[1])
        return
    sys.exit(__doc__)


if __name__ == "__main__":
    main()
