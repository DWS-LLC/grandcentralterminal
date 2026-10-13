#!/usr/bin/env python3
"""GCT x Celery Man: shot-for-shot build (stdlib + ffmpeg + ImageMagick + say).

    shots (SHOTS, ref cut times) --> per-shot ffmpeg segment --> concat
    lines (LINES) --> say --> mix with music --> gct-celeryman.mp4

Run:  python3 -I demo/celeryman/build.py [shots|audio|mux|all] [shot numbers...]
Plates come from ~/Movies/GCT Reel/stock (demo/media/gen.py), see STORYBOARD.md.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys
import zlib
from dataclasses import dataclass, field, replace

# --- Frame ---------------------------------------------------------------------
W, H, FPS = 1920, 1080, 30
CYAN = "0x1aa3d0"
SAGE = "0x9db39a"
SCALE = 1.45
TH = int(26 * SCALE)
BD = int(4 * SCALE)
FONT_UI = "/System/Library/Fonts/Helvetica.ttc"
FONT_MONO = "/Users/dubey/Library/Fonts/JetBrainsMonoNerdFont-Bold.ttf"
FONT_BIG = "/System/Library/Fonts/Supplemental/Impact.ttf"

# --- Paths ---------------------------------------------------------------------
REEL = pathlib.Path.home() / "Movies/GCT Reel"
STOCK = REEL / "stock"
OUT = REEL / "out/celeryman"
WORK = OUT / "work"
SEGS = WORK / "segs"
ART = WORK / "art"
VOX = WORK / "vox"
MUSIC = REEL / "music/celeryman.mp3"
FINAL = OUT / "gct-celeryman.mp4"

# Ref cut points (s); shot n spans CUTS[n-1]..CUTS[n]. See STORYBOARD.md.
CUTS = [0, 1.8, 4.0, 6.8, 8.4, 9.7, 11.0, 11.7, 14.1, 15.9, 18.4, 24.1, 26.1, 28.2, 30.7,
        32.6, 34.3, 36.0, 38.6, 39.4, 40.3, 45.2, 47.4, 49.6, 52.5, 55.2, 57.8, 62.8, 64.3,
        65.7, 67.5, 71.8, 73.2, 77.2, 78.9, 80.6, 83.8, 85.4, 88.7, 89.8, 91.3, 94.0, 96.2,
        98.9, 100.5, 102.7, 103.0]
STROBE_END = 106.3
END_CARD_S = 2.5
PARODY_LABEL_S = 5


@dataclass
class Layer:
    """One thing on a shot: a plate, a window with a clip/text, or a flat rect."""
    kind: str                       # plate | win | rect | img
    clip: str = ""                  # stock plate name (no .mp4)
    ss: float = 0.0                 # clip start offset
    crop: tuple = (0, 0, 1, 1)      # fractional crop of the clip: x y w h
    zoom: float = 1.0               # plate zoom
    pan: tuple = (0.5, 0.5)         # plate crop anchor
    x: int = 0
    y: int = 0
    w: int = 0
    h: int = 0
    title: str = ""
    t0: float = 0.0                 # pop-in time
    term: str = ""                  # terminal text (typed in)
    color: str = ""                 # rect color
    img: str = ""                   # prebuilt PNG name in ART
    speed: float = 520.0            # typing px/s


@dataclass
class Shot:
    layers: list = field(default_factory=list)
    bg: str = CYAN


def plate(clip, ss=0.0, zoom=1.0, pan=(0.5, 0.5)):
    return Layer("plate", clip=clip, ss=ss, zoom=zoom, pan=pan)


def win(x, y, w, h, title="", clip="", ss=0.0, crop=(0, 0, 1, 1), t0=0.0, term="", speed=520.0):
    return Layer("win", clip=clip, ss=ss, crop=crop, x=x, y=y, w=w, h=h, title=title, t0=t0,
                 term=term, speed=speed)


def rect(x, y, w, h, color):
    return Layer("rect", x=x, y=y, w=w, h=h, color=color)


def img(name, x, y, t0=0.0):
    return Layer("img", img=name, x=x, y=y, t0=t0)


# Dancer crops: vertical strip around the figure.
DANCER = (0.33, 0.0, 0.34, 1.0)
HOODIE = (0.12, 0.0, 0.5, 1.0)
TANK = (0.2, 0.0, 0.6, 1.0)


def term(x, y, w, h, text, t0=0.0, speed=520.0):
    return win(x, y, w, h, "Sam's COMPUTER", term=text, t0=t0, speed=speed)


def dancer_win(clip, x, y, ss=0.0, t0=0.0, title="DARIO", crop=DANCER, w=300, h=640):
    return win(x, y, w, h, title, clip=clip, ss=ss, crop=crop, t0=t0)


def head_win(x, y, ss=0.0, t0=0.0, w=520, h=380, title="Dario"):
    return win(x, y, w, h, title, clip="pl-head-pink", ss=ss, t0=t0)


def stack(n, x, y, w, h, step=16):
    return [win(x + i * step, y - i * 6, w, h, "DARIO") for i in range(n)]


SHOTS: dict[int, Shot] = {
    1: Shot([plate("pl-catwalk", 0.0)]),
    2: Shot([plate("pl-catwalk", 2.0, 1.4, (0.7, 0.5))]),
    3: Shot([plate("pl-wide-desk", 0.0)]),
    4: Shot([plate("pl-cu-sip", 0.0)]),
    5: Shot([plate("pl-over-shoulder", 0.0)]),
    6: Shot([plate("pl-macro-keys", 0.0)]),
    7: Shot([plate("pl-over-shoulder", 3.0, 1.3, (0.4, 0.4))]),
    8: Shot([img("splash", 740, 260), term(110, 610, 460, 90, "Good morning, Sam", 0.3, 300)]),
    9: Shot([plate("pl-wide-desk", 2.0, 1.2, (0.6, 0.55))]),
    10: Shot([plate("pl-cu-down", 0.0)]),
    11: Shot([term(60, 700, 440, 90, "", 0), dancer_win("pl-dance-jacket", 1500, 20, 0.0)]),
    12: Shot([plate("pl-ms-monitor", 3.5)]),
    13: Shot([head_win(120, 120, 0.0), dancer_win("pl-dance-jacket", 1300, 60, 1.0)]),
    14: Shot([plate("pl-cu-down", 2.5)]),
    15: Shot([head_win(120, 120, 2.0), dancer_win("pl-dance-jacket", 1300, 60, 2.5)]),
    16: Shot([plate("pl-wide-desk", 3.0)]),
    17: Shot([plate("pl-ms-monitor", 0.0)]),
    18: Shot([head_win(120, 120, 3.0), term(60, 700, 440, 90, "4d4d4d3 Engaged", 0.2, 330),
              dancer_win("pl-dance-jacket", 1300, 60, 3.2)]),
    19: Shot([plate("pl-cu-down", 3.5)]),
    20: Shot([plate("pl-macro-keys", 3.0)]),
    21: Shot([head_win(60, 220, 4.0, title="Dario"), term(60, 700, 520, 90, "add pane: OYSTER", 0.2, 360),
              win(600, 120, 520, 640, "OYSTER", clip="pl-dance-hoodie", ss=0.0, crop=HOODIE, t0=0.5)]),
    22: Shot([plate("pl-ms-monitor", 1.5, 1.2, (0.6, 0.5))]),
    23: Shot([rect(0, 0, W, H, "0x7a6a58"), rect(480, 120, 960, 760, "0xf2f2f2"),
              win(560, 150, 800, 700, "printout", clip="pl-dance-hoodie", ss=2.0, crop=HOODIE)], bg="0x7a6a58"),
    24: Shot([plate("pl-ms-monitor", 4.0)]),
    25: Shot([term(560, 280, 800, 340, "I have a BETA pane\nI have been working on.\nWould you like to see it?", 0.2, 640)]),
    26: Shot([plate("pl-cu-down", 1.0)]),
    27: Shot([win(700, 60, 520, 440, "Dario", clip="pl-dance-fedora", ss=0.5, crop=(0.36, 0.08, 0.28, 0.4), t0=0.0),
              head_win(300, 460, 1.0, 0.3, 420, 300, "BETA")]),
    28: Shot([plate("pl-ms-monitor", 2.0, 1.1, (0.6, 0.5))]),
    29: Shot([dancer_win("pl-dance-fedora", 120, 80, 0.5), img("dario_card", 520, 260, 0.2),
              dancer_win("pl-dance-fedora", 1500, 80, 1.5, 0.1)]),
    30: Shot([plate("pl-ms-monitor", 5.0)]),
    31: Shot(stack(7, 150, 300, 300, 640) + [dancer_win("pl-dance-fedora", 900, 100, 3.0)]),
    32: Shot([plate("pl-ms-monitor", 1.0)]),
    33: Shot(stack(5, 700, 100, 520, 380, 36) + [term(60, 700, 420, 90, "FLARHGUN", 0.1, 250)]),
    34: Shot([dancer_win("pl-dance-fedora", 150, 100, 3.5), dancer_win("pl-dance-fedora", 800, 100, 3.7, 0.1),
              dancer_win("pl-dance-fedora", 1450, 100, 3.9, 0.2)]),
    35: Shot([plate("pl-wide-desk", 4.0, 1.1, (0.5, 0.5))]),
    36: Shot([plate("pl-ms-monitor", 2.5)]),
    37: Shot([dancer_win("pl-dance-fedora", 1300, 40, 4.5), img("nsfw", 400, 520)]),
    38: Shot([plate("pl-cu-sip", 2.0)]),
    39: Shot([plate("pl-ms-monitor", 5.5)]),
    40: Shot([plate("pl-wide-desk", 5.0)]),
    41: Shot([plate("pl-cu-sip", 4.5)]),
    42: Shot([rect(0, 0, W, H, "0xf0c8a0"), dancer_win("pl-dance-fedora", 800, 40, 2.0, title="Dario"),
              img("wife", 760, 250, 0.2)], bg=SAGE),
    43: Shot([plate("pl-ms-monitor", 4.5)]),
    44: Shot([plate("pl-cu-down", 4.0)]),
    45: Shot(stack(8, 100, 360, 300, 640, 30) + [win(900, 80, 420, 760, "DARIO", clip="pl-dance-tank", ss=1.0, crop=TANK)]),
    46: Shot([head_win(0, 0, 1.0, w=700, h=500), head_win(600, 300, 2.0, w=700, h=500),
              head_win(1200, 100, 3.0, w=700, h=500), head_win(300, 580, 4.0, w=700, h=500)]),
}

# Strobe after shot 46: quick comps from other shots.
STROBE = [21, 29, 31, 45, 33, 34, 37, 46, 29, 45, 31, 21]

# --- Dialogue ------------------------------------------------------------------
SAM, COMPUTER, DARIO = "Reed (English (US))", "Samantha", "Fred"
LINES = [
    (12.9, COMPUTER, "Good morning, Sam. What will your first pane of the day be?"),
    (16.0, SAM, "Computer, load up GCT, please."),
    (23.0, COMPUTER, "Yes, Sam."),
    (32.6, SAM, "Could you kick up the, uh, four D four D four D three? Engage."),
    (41.5, SAM, "Add pane. Oyster?"),
    (45.8, SAM, "Uh, give me a printout of Oyster smiling."),
    (47.6, COMPUTER, "Okay."),
    (49.6, SAM, "Computer."),
    (50.4, COMPUTER, "Yes."),
    (50.9, SAM, "Do we have any new panes?"),
    (52.7, COMPUTER, "I have a beta pane I have been working on. Would you like to see it?"),
    (57.3, SAM, "All right."),
    (58.3, COMPUTER, "Okay."),
    (59.6, DARIO, "Hey, Sam. I'm Dario, your latest model. I can't wait to be helpful."),
    (63.0, SAM, "Now, Dario I can get into."),
    (71.9, SAM, "Could I see a split pane?"),
    (74.0, COMPUTER, "Yes."),
    (74.8, SAM, "And a detach?"),
    (76.0, COMPUTER, "Yes."),
    (77.5, SAM, "Is there any way to generate an unaligned Dario?"),
    (81.0, COMPUTER, "Not computing. Please repeat."),
    (82.9, SAM, "Unaligned Dario."),
    (84.2, COMPUTER, "This is not suitable for work. Are you sure?"),
    (86.8, SAM, "Mhm."),
    (87.6, COMPUTER, "Okay."),
    (94.2, COMPUTER, "Excuse me, Sam. Your wife is on the phone. It's an emergency."),
    (98.6, SAM, "I'll get it later. We have important work to do."),
]


def run(cmd: list) -> None:
    done = subprocess.run([str(c) for c in cmd], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if done.returncode != 0:
        sys.exit(done.stderr.decode()[-1500:])


# --- Art (ImageMagick) ---------------------------------------------------------
def win_png(w: int, h: int, title: str, black: bool) -> pathlib.Path:
    out = ART / f"win-{w}x{h}-{zlib.crc32(title.encode())}-{int(black)}.png"
    if out.exists():
        return out

    body = "black" if black else "white"
    run(["magick", "-size", f"{w}x{h}", "xc:#c3c3c3",
         "-fill", "#0a246a", "-draw", f"rectangle 3,3 {w - 4},{TH - 5}",
         "-fill", "white", "-font", FONT_UI, "-pointsize", str(int(15 * SCALE)), "-annotate", f"+{2 * BD}+{TH - 9}", title,
         "-fill", "#c3c3c3", "-draw", f"rectangle {w - TH + 4},5 {w - 7},{TH - 7}",
         "-fill", "black", "-pointsize", str(int(13 * SCALE)), "-annotate", f"+{w - TH + 9}+{TH - 9}", "x",
         "-fill", body, "-draw", f"rectangle {BD},{TH} {w - BD - 1},{h - BD - 1}",
         "-fill", "none", "-stroke", "#404040", "-draw", f"rectangle 0,0 {w - 1},{h - 1}", out])
    return out


def text_png(name: str, text: str, size: int, color: str, font: str = FONT_MONO) -> pathlib.Path:
    out = ART / f"{name}.png"
    run(["magick", "-background", "none", "-fill", color, "-font", font, "-pointsize", str(size),
         f"label:{text}", out])
    return out


def build_art() -> None:
    ART.mkdir(parents=True, exist_ok=True)

    # Splash: yellow-orange header, product name, bar track.
    run(["magick", "-size", "440x330", "xc:#c3c3c3",
         "-fill", "#0a246a", "-draw", "rectangle 3,3 436,21",
         "-fill", "white", "-font", FONT_UI, "-pointsize", "15", "-annotate", "+8+19", "GCT Identity Generator 1.0",
         "(", "-size", "430x200", "gradient:#ffd23a-#ff9a1a", ")", "-geometry", "+5+26", "-composite",
         "-fill", "#0a246a", "-font", FONT_BIG, "-pointsize", "58", "-annotate", "+100+170", "GCT",
         "-fill", "black", "-font", FONT_UI, "-pointsize", "20", "-annotate", "+60+260", "GCT Identity Generator 1.0",
         "-fill", "white", "-draw", "rectangle 20,275 420,293",
         "-fill", "black", "-pointsize", "13", "-annotate", "+330+320", "please wait...",
         "-fill", "none", "-stroke", "#404040", "-draw", "rectangle 0,0 439,329", ART / "splash.png"])

    # "DARIO" orange title card, "NSFW" card, incoming-call card.
    run(["magick", "-size", "420x300", "xc:#ff8a1f", "-fill", "black", "-font", FONT_BIG,
         "-pointsize", "130", "-gravity", "center", "-annotate", "+0+0", "DARIO", ART / "dario_card.png"])
    run(["magick", "-size", "1100x240", "xc:#e8e8e8", "-stroke", "#404040", "-fill", "none",
         "-draw", "rectangle 0,0 1099,239", "-stroke", "none", "-fill", "black", "-font", FONT_BIG,
         "-pointsize", "150", "-gravity", "center", "-annotate", "+0+0", "NSFW", ART / "nsfw.png"])
    run(["magick", "-size", "400x480", "xc:#f3ede4", "-stroke", "#404040", "-fill", "none",
         "-draw", "rectangle 0,0 399,479", "-stroke", "none", "-fill", "#d12a5a",
         "-draw", "roundrectangle 60,150 340,430 12,12", "-fill", "white", "-font", FONT_BIG,
         "-pointsize", "70", "-annotate", "+120+400", "WIFE", "-fill", "#d12a2a", "-font", FONT_MONO,
         "-pointsize", "32", "-annotate", "+70+110", "INCOMING CALL", ART / "wife.png"])


# --- Segments (ffmpeg) ---------------------------------------------------------
def term_assets(layer: Layer, k: int) -> pathlib.Path | None:
    if not layer.term:
        return None
    return text_png(f"term-{k}-{zlib.crc32(layer.term.encode())}", layer.term, int(24 * SCALE), "#e8e8e8")


def scaled(layer: Layer) -> Layer:
    w, h = int(layer.w * SCALE), int(layer.h * SCALE)
    x = min(int(layer.x * SCALE), W - w - 10) if layer.kind == "win" else int(layer.x * SCALE)
    y = min(int(layer.y * SCALE), H - h - 10) if layer.kind == "win" else int(layer.y * SCALE)
    return replace(layer, x=max(x, 10), y=max(y, 10), w=w, h=h, speed=layer.speed * SCALE)


def render_shot(name: str, shot: Shot, dur: float) -> pathlib.Path:
    out = SEGS / f"{name}.mp4"
    inputs: list = ["-f", "lavfi", "-i", f"color=c={shot.bg}:s={W}x{H}:r={FPS}:d={dur:.3f}"]
    chain: list[str] = []
    cur = "[0:v]"
    n_in = 1
    tag = 0

    def add(args: list) -> int:
        nonlocal n_in
        inputs.extend(args)
        n_in += 1
        return n_in - 1

    def overlay(src_label: str, x: str, y: str, t0: float) -> None:
        nonlocal cur, tag
        tag += 1
        nxt = f"[v{tag}]"
        chain.append(f"{cur}{src_label}overlay={x}:{y}:enable='gte(t,{t0:.2f})'{nxt}")
        cur = nxt

    for i, layer in enumerate(shot.layers):
        # UI layers are authored at 1x; scale up and keep them on screen.
        if layer.kind in ("win", "img"):
            layer = scaled(layer)

        if layer.kind == "plate":
            k = add(["-ss", f"{layer.ss}", "-stream_loop", "-1", "-i", STOCK / f"{layer.clip}.mp4"])
            chain.append(
                f"[{k}:v]fps={FPS},scale={int(W * layer.zoom)}:{int(H * layer.zoom)}:"
                f"force_original_aspect_ratio=increase,crop={W}:{H}:(iw-{W})*{layer.pan[0]}:(ih-{H})*{layer.pan[1]},"
                f"setsar=1[p{i}]")
            overlay(f"[p{i}]", "0", "0", 0)
            continue

        if layer.kind == "rect":
            k = add(["-f", "lavfi", "-i", f"color=c={layer.color}:s={layer.w}x{layer.h}:r={FPS}:d={dur:.3f}"])
            overlay(f"[{k}:v]", str(layer.x), str(layer.y), layer.t0)
            continue

        if layer.kind == "img":
            k = add(["-loop", "1", "-t", f"{dur:.3f}", "-i", ART / f"{layer.img}.png"])
            chain.append(f"[{k}:v]scale=iw*{SCALE}:ih*{SCALE}[i{i}]")
            overlay(f"[i{i}]", str(layer.x), str(layer.y), layer.t0)
            continue

        # win: frame, then clip or typed text inside it
        black = bool(layer.term) or layer.title.endswith("COMPUTER")
        frame = win_png(layer.w, layer.h, layer.title, black)
        k = add(["-loop", "1", "-t", f"{dur:.3f}", "-i", frame])
        overlay(f"[{k}:v]", str(layer.x), str(layer.y), layer.t0)

        cw, ch = layer.w - 2 * BD, layer.h - TH - BD
        if layer.clip:
            cx, cy, cwf, chf = layer.crop
            k = add(["-ss", f"{layer.ss}", "-stream_loop", "-1", "-i", STOCK / f"{layer.clip}.mp4"])
            src = f"[{k}:v]fps={FPS},crop=iw*{cwf}:ih*{chf}:iw*{cx}:ih*{cy}"
            if cwf >= 0.9:
                # Wide clips fill the window.
                chain.append(f"{src},scale={cw}:{ch}:force_original_aspect_ratio=increase,"
                             f"crop={cw}:{ch},setsar=1[c{i}]")
                overlay(f"[c{i}]", str(layer.x + BD), str(layer.y + TH), layer.t0)
            else:
                # Narrow crops (dancers) letterbox on a white pad the size of the window body.
                white = add(["-f", "lavfi", "-i", f"color=c=white:s={cw}x{ch}:r={FPS}:d={dur:.3f}"])
                chain.append(f"{src},scale={cw}:{ch}:force_original_aspect_ratio=decrease,setsar=1[d{i}]")
                chain.append(f"[{white}:v][d{i}]overlay=(W-w)/2:(H-h)/2[c{i}]")
                overlay(f"[c{i}]", str(layer.x + BD), str(layer.y + TH), layer.t0)

        text = term_assets(layer, i)
        if text is None:
            continue

        # Typing: on a black pad the size of the window body, text sits under a black
        # box that sweeps right to uncover it. The pad clips the box to the window.
        pad = add(["-f", "lavfi", "-i", f"color=c=black:s={cw}x{ch}:r={FPS}:d={dur:.3f}"])
        k = add(["-loop", "1", "-t", f"{dur:.3f}", "-i", text])
        box = add(["-f", "lavfi", "-i", f"color=c=black:s={cw}x{ch}:r={FPS}:d={dur:.3f}"])
        sweep = f"10+max(0\\,t-{layer.t0:.2f})*{layer.speed}"
        chain.append(f"[{pad}:v][{k}:v]overlay=10:8[tx{i}]")
        chain.append(f"[tx{i}][{box}:v]overlay={sweep}:0[ty{i}]")
        overlay(f"[ty{i}]", str(layer.x + BD), str(layer.y + TH), layer.t0)

    chain.append(f"{cur}format=yuv420p[out]")
    run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", ";".join(chain),
         "-map", "[out]", "-t", f"{dur:.3f}", "-r", FPS, "-an",
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "16", "-pix_fmt", "yuv420p", out])
    return out


def chyron(name: str, text: str, size: int) -> pathlib.Path:
    return text_png(name, text, size, "white", FONT_UI)


def end_card() -> pathlib.Path:
    out = SEGS / "end.mp4"
    big = text_png("end-big", "GCT", 260, "white", FONT_BIG)
    small = text_png("end-small", "Grand Central Terminal   A PARODY", 34, "#9aa0a6", FONT_UI)
    run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"color=c=black:s={W}x{H}:r={FPS}:d={END_CARD_S}",
         "-loop", "1", "-i", big, "-loop", "1", "-i", small, "-filter_complex",
         f"[0][1]overlay=(W-w)/2:(H-h)/2-60[a];[a][2]overlay=(W-w)/2:H/2+150,format=yuv420p[o]",
         "-map", "[o]", "-t", str(END_CARD_S), "-r", FPS, "-c:v", "libx264", "-crf", "16", out])
    return out


def build_shots(only: list[int]) -> None:
    SEGS.mkdir(parents=True, exist_ok=True)
    build_art()
    for n in sorted(SHOTS):
        if only and n not in only:
            continue
        dur = CUTS[n] - CUTS[n - 1]
        print(f"shot {n:02d} {dur:.2f}s", flush=True)
        render_shot(f"s{n:02d}", SHOTS[n], dur)

    if only:
        return

    strobe_len = (STROBE_END - CUTS[-1]) / len(STROBE)
    for i, n in enumerate(STROBE):
        render_shot(f"x{i:02d}", SHOTS[n], strobe_len)
    end_card()

    names = [f"s{n:02d}" for n in sorted(SHOTS)] + [f"x{i:02d}" for i in range(len(STROBE))] + ["end"]
    listing = WORK / "concat.txt"
    listing.write_text("".join(f"file '{SEGS / (s + '.mp4')}'\n" for s in names))
    run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", listing,
         "-c:v", "libx264", "-crf", "16", "-pix_fmt", "yuv420p", "-r", FPS, WORK / "video.mp4"])


# --- Audio ---------------------------------------------------------------------
def build_audio() -> None:
    VOX.mkdir(parents=True, exist_ok=True)
    total = STROBE_END + END_CARD_S
    inputs: list = []
    delays: list[str] = []
    for i, (t, voice, text) in enumerate(LINES):
        aiff, wav = VOX / f"l{i:02d}.aiff", VOX / f"l{i:02d}.wav"
        run(["say", "-v", voice, "-r", "170", "-o", aiff, text])
        run(["ffmpeg", "-v", "error", "-y", "-i", aiff, "-ar", "44100", "-ac", "2", wav])
        inputs.extend(["-i", wav])
        delays.append(f"[{i}:a]adelay={int(t * 1000)}|{int(t * 1000)},volume=1.6[a{i}]")

    voices = "".join(f"[a{i}]" for i in range(len(LINES)))
    k = len(LINES)
    music = ["-i", MUSIC] if MUSIC.exists() else ["-f", "lavfi", "-i", f"anullsrc=r=44100:cl=stereo:d={total}"]
    graph = ";".join(delays + [
        f"{voices}amix=inputs={k}:normalize=0,apad=whole_dur={total}[v]",
        f"[{k}:a]atrim=0:{total},volume=0.28,afade=t=out:st={total - 2}:d=2[m]",
        "[v][m]amix=inputs=2:normalize=0,alimiter=limit=0.95[out]"])
    run(["ffmpeg", "-v", "error", "-y", *inputs, *music, "-filter_complex", graph, "-map", "[out]",
         "-t", f"{total}", WORK / "audio.wav"])


def mux() -> None:
    # Opening label: bottom-left for the first PARODY_LABEL_S seconds.
    label = chyron("label", "A GCT PARODY", 40)
    run(["ffmpeg", "-v", "error", "-y", "-i", WORK / "video.mp4", "-i", WORK / "audio.wav", "-i", label,
         "-filter_complex", f"[0:v][2:v]overlay=40:H-h-40:enable='lt(t,{PARODY_LABEL_S})',format=yuv420p[v]",
         "-map", "[v]", "-map", "1:a", "-c:v", "libx264", "-crf", "16", "-c:a", "aac", "-b:a", "192k",
         "-shortest", FINAL])
    print(f"wrote {FINAL}")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    cmd = sys.argv[1] if len(sys.argv) > 1 else "all"
    only = [int(a) for a in sys.argv[2:]]
    if cmd in ("shots", "all"):
        build_shots(only)
    if cmd in ("audio", "all"):
        build_audio()
    if cmd in ("mux", "all"):
        mux()


if __name__ == "__main__":
    main()
