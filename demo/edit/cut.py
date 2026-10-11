"""Assemble the reel from an edit list: python3 -I demo/edit/cut.py demo/edit/hype.json

    edl.json --> per-shot segments (trim, speed, scale, fps, caption) --> concat
             --> music bed (fade out) --> reel-4k.mp4 + reel-1080.mp4

Captions are PNG cards rendered by ImageMagick (this ffmpeg has no
drawtext) and overlaid with a short fade. Everything lands in
~/Movies/GCT Reel/out/<edl name>/.
"""

import json
import pathlib
import shutil
import subprocess
import sys

REEL = pathlib.Path.home() / "Movies/GCT Reel"
FONTS = pathlib.Path.home() / "Library/Fonts"
FONT_TITLE = FONTS / "JetBrainsMonoNerdFontMono-ExtraBold.ttf"
FONT_HINT = FONTS / "JetBrainsMonoNerdFontMono-Medium.ttf"
W, H, FPS = 3840, 2160, 60
CAPTION_FADE = 0.25       # seconds in/out
MUSIC_FADE = 1.5          # seconds at the tail
# Caption card geometry (4K px): bottom-left panel.
PANEL_X, PANEL_BOTTOM, PAD = 140, 180, 56
TITLE_PT, HINT_PT, GAP = 104, 56, 22
PANEL_FILL = "#0b0c12c8"
TITLE_FILL = "#f2f3f7"


def run(cmd: list) -> None:
    subprocess.run([str(c) for c in cmd], check=True)


def text_size(font: pathlib.Path, pt: int, text: str) -> tuple[int, int]:
    out = subprocess.run(["magick", "-background", "none", "-font", str(font),
                          "-pointsize", str(pt), f"label:{text}",
                          "-format", "%w %h", "info:"],
                         capture_output=True, text=True, check=True).stdout
    w, h = out.split()
    return int(w), int(h)


def caption_card(path: pathlib.Path, title: str, hint: str, accent: str) -> None:
    # Panel sized to the wider line; hint line optional.
    tw, th = text_size(FONT_TITLE, TITLE_PT, title)
    hw, hh = text_size(FONT_HINT, HINT_PT, hint) if hint else (0, 0)
    pw = max(tw, hw) + 2 * PAD
    ph = th + (GAP + hh if hint else 0) + 2 * PAD
    x0, y1 = PANEL_X, H - PANEL_BOTTOM
    y0 = y1 - ph

    cmd = ["magick", "-size", f"{W}x{H}", "xc:none",
           "-fill", PANEL_FILL,
           "-draw", f"roundrectangle {x0},{y0} {x0 + pw},{y1} 28,28",
           "-fill", accent, "-draw", f"rectangle {x0},{y0 + 24} {x0 + 10},{y1 - 24}",
           "-font", FONT_TITLE, "-pointsize", TITLE_PT, "-fill", TITLE_FILL,
           "-gravity", "NorthWest",
           "-annotate", f"+{x0 + PAD}+{y0 + PAD - 8}", title]
    if hint:
        cmd += ["-font", FONT_HINT, "-pointsize", HINT_PT, "-fill", accent,
                "-annotate", f"+{x0 + PAD}+{y0 + PAD + th + GAP - 8}", hint]
    run(cmd + [path])


def source_path(shot: dict) -> pathlib.Path:
    # "take:hero-tokyo-night" | "stock:splitflap" | absolute path
    kind, _, name = shot["src"].partition(":")
    if kind == "take":
        return REEL / "takes" / f"{name}.mov"
    if kind == "stock":
        return REEL / "stock" / f"{name}.mp4"
    return pathlib.Path(shot["src"])


def title_card(path: pathlib.Path, title: str, sub: str, accent: str) -> None:
    # End card: centered wordmark + tagline on a soft dark band.
    band = f"rectangle 0,{H // 2 - 300} {W},{H // 2 + 300}"
    run(["magick", "-size", f"{W}x{H}", "xc:none",
         "-fill", "#08090dd8", "-draw", band, "-gravity", "Center",
         "-font", FONT_TITLE, "-pointsize", 190, "-fill", TITLE_FILL,
         "-annotate", "+0-70", title,
         "-font", FONT_HINT, "-pointsize", 72, "-fill", accent,
         "-annotate", "+0+120", sub, path])


def render_shot(i: int, shot: dict, frames: int, work: pathlib.Path,
                accent: str) -> pathlib.Path:
    # One segment: trim -> speed -> cover-scale to 4K -> 60fps -> card.
    # `frames` comes from cumulative beat times so cuts never drift.
    speed = shot.get("speed", 1.0)
    dur = frames / FPS
    src_len = dur * speed + 0.5
    out = work / f"seg{i:03d}.mov"

    vf = (f"setpts=PTS/{speed},scale={W}:{H}:force_original_aspect_ratio=increase"
          f":flags=lanczos,crop={W}:{H},fps={FPS},format=yuv420p")
    if "crop" in shot:
        # crop: [x, y, w, h] in source fractions, applied before scaling.
        x, y, cw, ch = shot["crop"]
        vf = f"crop=iw*{cw}:ih*{ch}:iw*{x}:ih*{y}," + vf

    cmd = ["ffmpeg", "-v", "error", "-y", "-ss", shot.get("in", 0), "-t", src_len,
           "-i", source_path(shot)]
    caption = shot.get("caption")
    title = shot.get("title")
    if not caption and not title:
        cmd += ["-vf", vf]
    else:
        card = work / f"cap{i:03d}.png"
        # Captions fade in/out within the shot; the end card fades in late
        # (card_at) and holds to the last frame.
        fade_in_at, fade_in = 0.1, CAPTION_FADE
        fade_out = max(dur - CAPTION_FADE, 0)
        if title:
            title_card(card, title[0], title[1], accent)
            fade_in_at, fade_in, fade_out = shot.get("card_at", 0.1), 0.6, dur
        else:
            caption_card(card, caption[0], caption[1] if len(caption) > 1 else "", accent)
        cmd += ["-loop", "1", "-t", dur, "-i", card, "-filter_complex",
                f"[0:v]{vf}[v];[1:v]format=rgba,"
                f"fade=in:st={fade_in_at}:d={fade_in}:alpha=1,"
                f"fade=out:st={fade_out}:d={CAPTION_FADE}:alpha=1[c];"
                f"[v][c]overlay=0:0:shortest=1,format=yuv420p"]
    cmd += ["-an", "-frames:v", frames, "-c:v", "prores_videotoolbox",
            "-profile:v", "hq", out]
    run(cmd)
    return out


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    edl_path = pathlib.Path(sys.argv[1])
    edl = json.loads(edl_path.read_text())
    out_dir = REEL / "out" / edl_path.stem
    work = out_dir / "work"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    accent = edl.get("accent", "#7aa2f7")

    # Frame counts from cumulative cut times: each cut lands on the nearest
    # frame of its beat, so rounding never accumulates (a beat at 128 BPM
    # is 28.125 frames at 60fps).
    shots = edl["shots"]
    cuts, t = [0], 0.0
    for s in shots:
        t += s["dur"]
        cuts.append(round(t * FPS))
    segs = [render_shot(i, s, cuts[i + 1] - cuts[i], work, accent)
            for i, s in enumerate(shots)]
    listing = work / "concat.txt"
    listing.write_text("".join(f"file '{s}'\n" for s in segs))
    total = cuts[-1] / FPS

    # Music bed: from music_in, faded at the tail, trimmed to the picture.
    music = REEL / "music" / edl["music"]
    fade_at = total - MUSIC_FADE
    master = out_dir / "reel-4k.mp4"
    run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", listing,
         "-ss", edl.get("music_in", 0), "-i", music,
         "-filter_complex", f"[1:a]afade=out:st={fade_at}:d={MUSIC_FADE}[a]",
         "-map", "0:v", "-map", "[a]", "-t", total,
         "-c:v", "hevc_videotoolbox", "-q:v", 72, "-tag:v", "hvc1",
         "-c:a", "aac", "-b:a", "320k", "-movflags", "+faststart", master])

    # Share copy: 1080p60 H.264, plays everywhere.
    share = out_dir / "reel-1080.mp4"
    run(["ffmpeg", "-v", "error", "-y", "-i", master,
         "-vf", "scale=1920:1080:flags=lanczos", "-c:v", "h264_videotoolbox",
         "-b:v", "16M", "-c:a", "copy", "-movflags", "+faststart", share])
    print(master)
    print(share)


if __name__ == "__main__":
    main()
