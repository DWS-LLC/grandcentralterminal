"""Kinetic type for the reel, after the Anduril / Surface launch films.

    head   big neo-grotesk caps, left-aligned; letters decode in left to
           right through random glyphs ("TO QDAT" -> "TO REBUILD")
    label  small caps, usually split across corners (tl + br)
    mono   KEY=VALUE terminal string, typed on behind a block cursor
    foot   tiny metadata row, three columns along the bottom edge
    mark   the wordmark, mid-size, for the last card
    subhead  a smaller head, for plates with little clear space
    line   Fury-style small sentence, typed on (no cursor)
    phase  X-BAT phase card: tiny tag, bold title, KEY  VALUE spec rows
    callout  spec label on a leader line pinned to a tracked 3D anchor

A shot's "type" is a list of elements:

    {"head": ["EVERY SHELL,", "ONE CANVAS."], "pos": "ml", "at": 0.2}
    {"label": "ONE DAEMON OWNS EVERY SHELL", "pos": "tl"}
    {"mono": "GCTD=RUNNING", "pos": "c", "at": 0.5}
    {"foot": ["GCT", "TMUX, ON AN INFINITE CANVAS", "BUILT ON LIBGHOSTTY"]}
    {"line": ["Build a terminal", "with no edges."], "pos": "ml"}
    {"phase": "SPAWN", "tag": "PHASE 01", "rows": [["PANES", "∞"]], "pos": "bl"}
    {"callout": "GCTD", "tag": "SUBSYSTEM 01", "sub": "OWNS EVERY PTY",
     "track": "xray:core", "dir": "ur"}

Tracks come from edit/airframe.py: work/airframe/tracks-<shot>.json holds
per-frame pixel positions per anchor; render(start=) is the shot's in-point
in frames, so callouts stay pinned when a render is cut mid-way.

Any element takes "ink" (default FILL) for light plates: "ink": "#1d1d1f".

render() writes one transparent 4K PNG per distinct look and hard-links
them into a 60fps sequence (f00000.png...), so a 4s shot with a 0.6s
reveal costs ~40 ImageMagick calls, not 240. Text cuts out with the shot.
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import random
import subprocess
from functools import lru_cache

W, H, FPS = 3840, 2160, 60
MARGIN = 170
FILL = "#f4f4f2"
GLYPHS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

DECODE_STEP = 1 / 34      # seconds per letter locking in
NOISE = 2                 # random glyphs running ahead of the locked text
LINE_LAG = 0.12           # each line starts this much after the previous
TYPE_STEP = 1 / 40        # mono: seconds per typed character
BLINK = 0.27              # mono: cursor half-period once typed
CURSOR = "█"

TRACKS = pathlib.Path.home() / "Movies/GCT Reel/work/airframe"
LEADER = (150, 560)       # callout: diagonal rise, then the shelf, px
GROW = 0.25               # callout: seconds for the leader to draw
ROW_LAG = 0.08            # phase: stagger between spec rows
ROW_COL = 420             # phase: value column offset, px

_FONTS = pathlib.Path("/Library/Fonts")
_MONO = pathlib.Path.home() / "Library/Fonts/JetBrainsMonoNerdFontMono-Medium.ttf"

# style: (font, pointsize, kerning, line height in px)
STYLES = {
    "head": (_FONTS / "SF-Pro-Display-Bold.otf", 250, -9, 232),
    "subhead": (_FONTS / "SF-Pro-Display-Bold.otf", 190, -7, 176),
    "label": (_FONTS / "SF-Pro-Display-Semibold.otf", 70, -1, 78),
    "mono": (_MONO, 88, 4, 110),
    "foot": (_FONTS / "SF-Pro-Display-Medium.otf", 34, 0, 40),
    "mark": (_FONTS / "SF-Pro-Display-Bold.otf", 132, -4, 140),
    "line": (_FONTS / "SF-Pro-Display-Medium.otf", 72, 0, 92),
    "tag": (_FONTS / "SF-Pro-Display-Medium.otf", 40, 2, 54),
    "phase": (_FONTS / "SF-Pro-Display-Bold.otf", 96, -2, 108),
    "row": (_MONO, 40, 1, 54),
    "callout": (_FONTS / "SF-Pro-Display-Bold.otf", 64, -1, 74),
}


@lru_cache(maxsize=None)
def _width(style: str, text: str) -> int:
    # Rendered width of the final string: anchors right/centred lines so
    # the reveal grows in place instead of sliding.
    font, pt, kern, _ = STYLES[style]
    cmd = ["magick", "-font", font, "-pointsize", pt, "-kerning", kern,
           "-background", "none", f"label:{text}", "-format", "%w", "info:"]
    out = subprocess.run([str(c) for c in cmd], capture_output=True, text=True,
                         check=True).stdout
    return int(out)


def _anchor(style: str, lines: list, pos: str) -> list:
    # Top-left corner of each line for a block anchored at pos:
    # t/m/b (top, middle, bottom) + l/r, or "c" (centred both ways).
    lh = STYLES[style][3]
    block = lh * len(lines)
    v, h = (pos[0], pos[1]) if pos != "c" else ("m", "c")
    y0 = {"t": MARGIN, "m": (H - block) // 2, "b": H - MARGIN - block}[v]
    out = []
    for k, line in enumerate(lines):
        w = _width(style, line)
        x = {"l": MARGIN, "r": W - MARGIN - w, "c": (W - w) // 2}[h]
        out.append((x, y0 + k * lh))
    return out


def _decode(line: str, t: float, rng: random.Random) -> str:
    # Locked prefix + a few random glyphs; spaces never scramble.
    if t < 0:
        return ""
    locked = int(t / DECODE_STEP)
    if locked >= len(line):
        return line
    head = line[:locked]
    for ch in line[locked:locked + NOISE]:
        head += ch if ch == " " else rng.choice(GLYPHS)
    return head


def _type_on(text: str, t: float) -> str:
    return "" if t < 0 else text[: int(t / TYPE_STEP)]


@lru_cache(maxsize=None)
def _track(ref: str) -> list:
    # "xray:core" -> [[x, y], ...] per render frame.
    shot, name = ref.split(":")
    return json.loads((TRACKS / f"tracks-{shot}.json").read_text())[name]


def _phase(el: dict, t: float, rng: random.Random) -> list:
    # Tag, decoding title, then spec rows typing on, as one block.
    rows = el.get("rows", [])
    tag_h, title_h, row_h = STYLES["tag"][3], STYLES["phase"][3], STYLES["row"][3]
    block = tag_h + title_h + 16 + row_h * len(rows)
    pos = el.get("pos", "bl")
    y = {"t": MARGIN, "m": (H - block) // 2, "b": H - MARGIN - block}[pos[0]]
    x = MARGIN if pos.endswith("l") else W - MARGIN - max(
        _width("phase", el["phase"]), ROW_COL + 300)
    out = [("tag", (x, y), el.get("tag", "") if t >= 0 else ""),
           ("phase", (x, y + tag_h), _decode(el["phase"], t - 0.1, rng))]
    for n, (k, v) in enumerate(rows):
        ry = y + tag_h + title_h + 16 + n * row_h
        rt = t - 0.35 - n * ROW_LAG
        out += [("row", (x, ry), _type_on(k, rt)), ("row", (x + ROW_COL, ry), _type_on(v, rt))]
    return out


def _callout(el: dict, t: float, frame: int, rng: random.Random) -> list:
    # Dot on the anchor, leader up and out, label on the shelf.
    pts = _track(el["track"])
    ax, ay = pts[min(frame, len(pts) - 1)]
    if t < 0:
        return []
    # dir: u/d (leader rises or drops) + l/r; "rise" overrides the diagonal.
    d = el.get("dir", "ur")
    sx = 1 if d.endswith("r") else -1
    sy = 1 if d.startswith("d") else -1
    rise, shelf = el.get("rise", LEADER[0]), LEADER[1]
    grow = min(1.0, t / GROW)
    ex, ey = ax + sx * rise * min(1, grow * 2), ay + sy * rise * min(1, grow * 2)
    fx = ex + sx * shelf * max(0, grow * 2 - 1)
    shapes = [("shape", (0, 0), f"circle {ax:.0f},{ay:.0f} {ax + 10:.0f},{ay:.0f}"),
              ("shape", (0, 0), f"line {ax:.0f},{ay:.0f} {ex:.0f},{ey:.0f}")]
    if grow > 0.5:
        shapes.append(("shape", (0, 0), f"line {ex:.0f},{ey:.0f} {fx:.0f},{ey:.0f}"))
    tx = ex if sx > 0 else ex - shelf
    title_y = ey - STYLES["callout"][3] - 8
    text = [("tag", (tx, title_y - STYLES["tag"][3]), el.get("tag", "") if grow >= 1 else ""),
            ("callout", (tx, title_y), _decode(el["callout"], t - GROW, rng)),
            ("row", (tx, ey + 14), _type_on(el.get("sub", ""), t - GROW - 0.2))]
    return shapes + text


def _typed(text: str, t: float) -> str:
    if t < 0:
        return ""
    n = int(t / TYPE_STEP)
    if n < len(text):
        return text[:n] + CURSOR
    on = int((t - len(text) * TYPE_STEP) / BLINK) % 2 == 0
    return text + (CURSOR if on else " ")


def _state(elements: list, t: float, frame: int, start: int = 0) -> list:
    # Every string visible at time t, with its style and position.
    draws = []
    for k, el in enumerate(elements):
        at = el.get("at", 0.1)
        pos = el.get("pos", "ml")
        ink = el.get("ink", FILL)
        start = len(draws)
        for style in ("head", "subhead", "mark"):
            if style not in el:
                continue
            lines = el[style]
            # Seed per frame + element: noise flickers, but reproducibly.
            rng = random.Random(frame * 131 + k)
            for n, (line, xy) in enumerate(zip(lines, _anchor(style, lines, pos))):
                draws.append((style, xy, _decode(line, t - at - n * LINE_LAG, rng)))
        rng = random.Random(frame * 131 + k)
        if "line" in el:
            lines = el["line"]
            for n, (line, xy) in enumerate(zip(lines, _anchor("line", lines, pos))):
                draws.append(("line", xy, _type_on(line, t - at - n * LINE_LAG * 3)))
        elif "phase" in el:
            draws += _phase(el, t - at, rng)
        elif "callout" in el:
            draws += _callout(el, t - at, start + frame, rng)
        elif "label" in el:
            lines = el["label"] if isinstance(el["label"], list) else [el["label"]]
            for line, xy in zip(lines, _anchor("label", lines, pos)):
                draws.append(("label", xy, line if t >= at else ""))
        elif "mono" in el:
            text = el["mono"]
            # Anchor on the final string + cursor so typing grows in place.
            (xy,) = _anchor("mono", [text + CURSOR], pos)
            draws.append(("mono", xy, _typed(text, t - at)))
        elif "foot" in el:
            cols = el["foot"]
            y = H - MARGIN // 2 - STYLES["foot"][3]
            xs = [MARGIN, (W - _width("foot", cols[1])) // 2, W - MARGIN - _width("foot", cols[2])]
            draws += [("foot", (x, y), c if t >= at else "") for x, c in zip(xs, cols)]
        draws[start:] = [(*d, ink) for d in draws[start:]]
    return [d for d in draws if d[2].strip()]


def _png(path: pathlib.Path, draws: list) -> None:
    cmd = ["magick", "-size", f"{W}x{H}", "xc:none", "-gravity", "NorthWest"]
    for style, (x, y), text, ink in draws:
        if style == "shape":
            cmd += ["-fill", "none", "-stroke", ink, "-strokewidth", 3, "-draw", text,
                    "-stroke", "none"]
            continue
        font, pt, kern, _ = STYLES[style]
        # %-escapes are live in -annotate; a leading @ would read a file.
        safe = text.replace("%", "%%")
        cmd += ["-fill", ink, "-font", font, "-pointsize", pt, "-kerning", kern,
                "-annotate", f"+{x}+{y}", safe]
    subprocess.run([str(c) for c in cmd + [path]], check=True)


def render(elements: list, frames: int, out_dir: pathlib.Path,
           start: int = 0) -> pathlib.Path:
    # Writes out_dir/f%05d.png for `frames` frames; returns the pattern.
    # start: the shot's in-point in source frames (callout tracks).
    out_dir.mkdir(parents=True, exist_ok=True)
    cache: dict[str, pathlib.Path] = {}
    for f in range(frames):
        draws = _state(elements, f / FPS, f, start)
        key = hashlib.sha1(repr(draws).encode()).hexdigest()
        if key not in cache:
            cache[key] = out_dir / f"s{len(cache):04d}.png"
            _png(cache[key], draws)
        link = out_dir / f"f{f:05d}.png"
        link.unlink(missing_ok=True)
        os.link(cache[key], link)
    return out_dir / "f%05d.png"
