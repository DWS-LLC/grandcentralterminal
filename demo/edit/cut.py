"""Assemble the reel from an edit list: python3 -I demo/edit/cut.py demo/edit/launch.json

    edl.json --> per-shot segments --> concat --> music bed (cut before the
             end card) --> reel-4k.mp4 + reel-1080.mp4

A shot is one source (take, stock clip or black) plus optional layers:

    plate ──┬─────────────────────────────────────────────┐
            │  screen: take → soften → corner-pin to quad │
            │          alpha = quad − holdouts − person   ├─▶ 60fps ─▶ text ─▶ seg
            └─────────────────────────────────────────────┘

  screen   real GCT footage on a generated wall/monitor. The person matte
           (edit/matte.swift, Vision) keeps the actor in front of it.
  caption  small centered lower third: 2-6 words + a key hint.
  card     one huge centered word ("1913").
  title    end card: wordmark + tagline.
  type     kinetic type (edit/titles.py): decode headlines, corner labels,
           typed KEY=VALUE strings, metadata footer.

Text is rendered by ImageMagick (this ffmpeg has no drawtext). Everything
lands in ~/Movies/GCT Reel/out/<edl name>/.
"""

from __future__ import annotations

import json
import pathlib
import shutil
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))   # -I drops the script dir
import titles  # noqa: E402

REEL = pathlib.Path.home() / "Movies/GCT Reel"
MATTES = REEL / "work/matte"
SFX = REEL / "work/sfx"          # edit/sfx.py output
FONTS = pathlib.Path.home() / "Library/Fonts"
FONT_TITLE = FONTS / "JetBrainsMonoNerdFontMono-ExtraBold.ttf"
FONT_HINT = FONTS / "JetBrainsMonoNerdFontMono-Medium.ttf"
W, H, FPS = 3840, 2160, 60
PLATE_FPS = 24            # generated B-roll (Veo) frame rate
VEO_PUNCH = 1.008         # Veo 4K plates carry 8px black bars top + bottom
HOLD = "tpad=stop_mode=clone:stop_duration=2"   # outlast the cut, then trim
TEXT_FADE = 0.25          # seconds in/out
MUSIC_TAIL = 0.35         # fade at music_out, then silence under the end card
TEXT_FILL = "#f2f3f7"

# Caption: centered, bottom edge CAPTION_BOTTOM px above the frame's.
CAPTION_PT, HINT_PT, CAPTION_GAP, CAPTION_BOTTOM = 104, 60, 22, 200
CARD_PT = 360
SHADOW = "70x16+0+0"      # ImageMagick -shadow: opacity x sigma
TYPE_SHADOW = (0.45, 24)  # kinetic type: soft black halo (alpha, blur sigma)


def run(cmd: list) -> None:
    subprocess.run([str(c) for c in cmd], check=True)


# --- Text layers ---------------------------------------------------------------
def _text_layer(path: pathlib.Path, draws: list) -> None:
    # Full-frame transparent PNG: text plus a soft shadow, so it reads on
    # both bright B-roll and dark terminals without a panel.
    run(["magick", "-size", f"{W}x{H}", "xc:none", "-gravity", "South", *draws,
         "(", "+clone", "-background", "black", "-shadow", SHADOW, ")",
         "+swap", "-background", "none", "-layers", "merge", "-crop", f"{W}x{H}+0+0",
         "+repage", path])


def caption_card(path: pathlib.Path, title: str, hint: str, accent: str) -> None:
    draws = ["-font", FONT_TITLE, "-pointsize", CAPTION_PT, "-fill", TEXT_FILL,
             "-annotate", f"+0+{CAPTION_BOTTOM + (HINT_PT + CAPTION_GAP if hint else 0)}", title]
    if hint:
        draws += ["-font", FONT_HINT, "-pointsize", HINT_PT, "-fill", accent,
                  "-annotate", f"+0+{CAPTION_BOTTOM}", hint]
    _text_layer(path, draws)


def word_card(path: pathlib.Path, word: str) -> None:
    run(["magick", "-size", f"{W}x{H}", "xc:none", "-gravity", "Center",
         "-font", FONT_TITLE, "-pointsize", CARD_PT, "-fill", TEXT_FILL,
         "-annotate", "+0+0", word,
         "(", "+clone", "-background", "black", "-shadow", SHADOW, ")",
         "+swap", "-background", "none", "-layers", "merge", "-crop", f"{W}x{H}+0+0",
         "+repage", path])


def title_card(path: pathlib.Path, title: str, sub: str, accent: str) -> None:
    # End card on black: wordmark + tagline, nothing else.
    run(["magick", "-size", f"{W}x{H}", "xc:none", "-gravity", "Center",
         "-font", FONT_TITLE, "-pointsize", 170, "-fill", TEXT_FILL,
         "-annotate", "+0-60", title,
         "-font", FONT_HINT, "-pointsize", 64, "-fill", accent,
         "-annotate", "+0+110", sub, path])


# --- Sources -------------------------------------------------------------------
def source_path(src: str) -> pathlib.Path:
    # "take:hero-tokyo-night" | "stock:op-2026" | "render:stack" | absolute path
    kind, _, name = src.partition(":")
    if kind == "take":
        return REEL / "takes" / f"{name}.mov"
    if kind == "render":
        return REEL / "render" / f"{name}.mov"
    if kind == "stock":
        return REEL / "stock" / f"{name}.mp4"
    return pathlib.Path(src)


def speed_chain(speed: float, blend: int) -> str:
    # Optional shutter: average `blend` frames (3x -> 3) before speeding
    # up. Off by default: on 60fps takes it ghosts text into double vision,
    # and plain frame-skipping is already smooth.
    smear = f"tmix=frames={blend}," if blend > 1 else ""
    return f"{smear}setpts=PTS/{speed}"


def cover(w: int = W, h: int = H) -> str:
    return (f"scale={w}:{h}:force_original_aspect_ratio=increase:flags=lanczos,"
            f"crop={w}:{h}")


# --- Screen composite ----------------------------------------------------------
def border_mask(path: pathlib.Path) -> None:
    # White frame with a black hairline edge: warped by perspective it
    # becomes the quad (outside pixels clamp to the black edge).
    run(["magick", "-size", f"{W - 4}x{H - 4}", "xc:white", "-bordercolor", "black",
         "-border", 2, path])


def tracked_quads(plate: pathlib.Path, quad: list, patches: list) -> list:
    # Per-plate-frame quads from edit/track.swift (Vision registration).
    tool = pathlib.Path(__file__).with_name("track.swift")
    out = subprocess.run(["swift", tool, plate, ",".join(map(str, quad)),
                          *(",".join(map(str, p)) for p in patches)],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def cubic(ys: list) -> list:
    # Least-squares cubic through ys over n = 0..len-1, via the 4x4 normal
    # equations: camera drift is smooth, and a polynomial fits one ffmpeg
    # expression (perspective can't take per-frame data).
    if len(set(ys)) == 1:
        # Static quad (locked-off plate): constant, and the 4x4 is singular.
        return [ys[0], 0.0, 0.0, 0.0]
    a = [[sum(n ** (r + c) for n in range(len(ys))) for c in range(4)] for r in range(4)]
    b = [sum(y * n ** r for n, y in enumerate(ys)) for r in range(4)]
    for col in range(4):
        piv = max(range(col, 4), key=lambda r: abs(a[r][col]))
        a[col], a[piv], b[col], b[piv] = a[piv], a[col], b[piv], b[col]
        for r in range(4):
            if r != col:
                f = a[r][col] / a[col][col]
                a[r] = [x - f * y for x, y in zip(a[r], a[col])]
                b[r] -= f * b[col]
    return [b[r] / a[r][r] for r in range(4)]


def _warp(series: list, first: int) -> str:
    # perspective filter from per-plate-frame corner lists (TL TR BL BR,
    # its order): one cubic per coordinate in n = plate frame =
    # perspective's input count + the plate's in-point.
    n = f"(in+{first})"
    exprs = []
    for k in range(8):
        c0, c1, c2, c3 = cubic([q[k] for q in series])
        exprs.append(f"'{c0:.4f}+{n}*({c1:.6f}+{n}*({c2:.8f}+{n}*{c3:.10f}))'")
    return "perspective=" + ":".join(exprs) + ":sense=destination:eval=frame"


def warps(scr: dict, plate: pathlib.Path, first: int) -> tuple[str, str]:
    # (screen warp: take frame -> wall quad, camera warp: frame 0 -> frame n).
    # EDL quads run clockwise (TL TR BR BL); perspective takes TL TR BL BR.
    quad = scr["quad"]
    order = [0, 1, 2, 3, 6, 7, 4, 5]
    if "track" not in scr:
        static = [[quad[k] for k in order]]
        return _warp(static, 0), _warp([[0, 0, W, 0, 0, H, W, H]], 0)

    quads = tracked_quads(plate, quad, scr["track"])
    # The track is a similarity (push + pan): recover scale and offset per
    # frame from the quad's top edge, then move the whole frame with it.
    frames = []
    for q in quads:
        s = (q[2] - q[0]) / (quad[2] - quad[0])
        bx, by = q[0] - s * quad[0], q[1] - s * quad[1]
        frames.append([bx, by, s * W + bx, by, bx, s * H + by, s * W + bx, s * H + by])
    return _warp([[q[k] for k in order] for q in quads], first), _warp(frames, first)


def holdout_mask(path: pathlib.Path, polygons: list) -> None:
    # White, with props in front of the wall that aren't people (a lamp)
    # as black polygons [x0, y0, x1, y1, ...] on frame 0; a 4px stroke pads
    # them. The camera warp carries the mask along with the push-in.
    cmd = ["magick", "-size", f"{W}x{H}", "xc:white", "-fill", "black",
           "-stroke", "black", "-strokewidth", 4]
    for poly in polygons:
        pts = " ".join(f"{poly[k]},{poly[k + 1]}" for k in range(0, len(poly), 2))
        cmd += ["-draw", f"polygon {pts}"]
    run(cmd + ["-blur", "0x1.5", path])


def screen_inputs(i: int, shot: dict, src_len: float, work: pathlib.Path) -> tuple[list, str]:
    # Returns (extra ffmpeg inputs, filter chain from [0:v]). Inputs:
    # 1 take, 2 border mask, 3 holdout mask, 4 person mattes (optional).
    scr = shot["screen"]
    speed = scr.get("speed", 1.0)
    plate = source_path(shot["src"])
    first = round(shot.get("in", 0) * PLATE_FPS)
    border, holdout = work / f"border{i:03d}.png", work / f"hold{i:03d}.png"
    border_mask(border)
    holdout_mask(holdout, scr.get("holdouts", []))
    warp, camera = warps(scr, plate, first)

    inputs = ["-ss", scr.get("in", 0), "-t", src_len * speed + 1,
              "-i", source_path(scr["src"]),
              "-loop", "1", "-framerate", PLATE_FPS, "-i", border,
              "-loop", "1", "-framerate", PLATE_FPS, "-i", holdout]
    # Projected light: eq grades in YUV, then the bloom blends in RGB (a
    # screen blend on chroma planes tints everything purple):
    # a touch soft, lifted blacks, a faint bloom.
    graph = (f"[1:v]{cover()},{speed_chain(speed, 1)},"
             f"fps={PLATE_FPS},eq=contrast=0.9:brightness=0.01,format=gbrp,gblur=sigma=1.2,"
             f"split[s0][s1];[s1]gblur=sigma=40[glow];"
             f"[s0][glow]blend=all_mode=screen:all_opacity=0.3,format=rgba,{warp}[scr];"
             f"[2:v]format=gray,{warp}[qw];[3:v]format=gray,{camera}[hm];"
             f"[qw][hm]blend=all_mode=multiply[qm];")
    alpha = "[qm]"
    if scr.get("matte"):
        mattes = MATTES / plate.stem
        if not mattes.is_dir():
            run(["swift", pathlib.Path(__file__).with_name("matte.swift"), plate, mattes])
        # Mattes are per plate frame; skip to the plate's in-point.
        inputs += ["-framerate", PLATE_FPS, "-start_number", first, "-i", mattes / "m%05d.png"]
        # Person = white in the matte; the screen goes where she isn't.
        graph += ("[4:v]format=gray,curves=all='0/0 0.15/0 0.85/1 1/1',negate[pm];"
                  f"{alpha}[pm]blend=all_mode=multiply[am];")
        alpha = "[am]"
    graph += (f"[scr]{alpha}alphamerge[lay];"
              f"[0:v]{cover()},fps={PLATE_FPS},format=rgba[plate];"
              f"[plate][lay]overlay=0:0:shortest=1")
    return inputs, graph


# --- Segments ------------------------------------------------------------------
def text_layer(i: int, shot: dict, dur: float, work: pathlib.Path,
               accent: str) -> tuple[pathlib.Path, float, float, float] | None:
    # (png, fade-in start, fade-in length, fade-out start) or None.
    png = work / f"txt{i:03d}.png"
    out_at = max(dur - TEXT_FADE, 0)
    if "title" in shot:
        title_card(png, *shot["title"], accent)
        return png, shot.get("card_at", 0.1), 0.6, dur
    if "card" in shot:
        word_card(png, shot["card"])
        return png, 0.0, 0.01, out_at
    if "caption" in shot:
        cap = shot["caption"]
        caption_card(png, cap[0], cap[1] if len(cap) > 1 else "", accent)
        return png, 0.1, TEXT_FADE, out_at
    return None


def render_shot(i: int, shot: dict, frames: int, work: pathlib.Path,
                accent: str) -> pathlib.Path:
    # One segment: plate (+ screen) -> speed -> 4K -> 60fps -> text.
    # `frames` comes from cumulative beat times so cuts never drift.
    speed = shot.get("speed", 1.0)
    dur = frames / FPS
    src_len = dur * speed + 0.5
    out = work / f"seg{i:03d}.mov"

    if shot["src"] == "black":
        cmd = ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
               f"color=black:s={W}x{H}:r={FPS}:d={dur + 1}"]
        graph = "[0:v]null"
    else:
        cmd = ["ffmpeg", "-v", "error", "-y", "-ss", shot.get("in", 0), "-t", src_len,
               "-i", source_path(shot["src"])]
        if "screen" in shot:
            extra, graph = screen_inputs(i, shot, src_len, work)
            cmd += extra
        else:
            graph = "[0:v]"
            if "crop" in shot:
                # crop: [x, y, w, h] in source fractions, applied before scaling.
                x, y, cw, ch = shot["crop"]
                graph += f"crop=iw*{cw}:ih*{ch}:iw*{x}:ih*{y},"
            blend = shot.get("blend", 1)
            graph += f"{cover()},{speed_chain(speed, blend)}"
        if "screen" in shot and speed != 1.0:
            graph += f",setpts=PTS/{speed}"
    punch = shot.get("punch", VEO_PUNCH if shot["src"].startswith("stock:") else 1)
    if punch != 1:
        # Centre zoom after compositing (quads stay in plate pixels): hides
        # the black bars on Veo plates.
        graph += f",scale={W}*{punch}:-2:flags=lanczos,crop={W}:{H}"
    graph += f",fps={FPS},format=yuv420p[v]"

    text = text_layer(i, shot, dur, work, accent)
    if "type" in shot:
        # Kinetic type: a 60fps PNG sequence over a soft black halo.
        seq = titles.render(shot["type"], frames, work / f"type{i:03d}",
                            start=round(shot.get("in", 0) * FPS))
        n = cmd.count("-i")
        # Dark ink on light plates gets no halo: "type_shadow": false.
        alpha, sigma = TYPE_SHADOW if shot.get("type_shadow", True) else (0, 1)
        cmd += ["-framerate", FPS, "-i", seq]
        graph += (f";[{n}:v]format=rgba,{HOLD},split[t][ts];"
                  f"[ts]colorchannelmixer=rr=0:gg=0:bb=0:aa={alpha},gblur=sigma={sigma}[sh];"
                  f"[v][sh]overlay=0:0[vs];[vs][t]overlay=0:0,format=yuv420p[v2]")
        label = "[v2]"
    elif text:
        png, in_at, in_len, out_at = text
        n = cmd.count("-i")
        # Text loops at the output rate and outlasts the shot: a 25fps loop
        # cut at `dur` ends the overlay (shortest=1) a few frames early, and
        # every short segment drifts the cuts off the beat.
        cmd += ["-loop", "1", "-framerate", FPS, "-t", dur + 1, "-i", png]
        graph += (f";[{n}:v]format=rgba,fade=in:st={in_at}:d={in_len}:alpha=1,"
                  f"fade=out:st={out_at}:d={TEXT_FADE}:alpha=1[t];"
                  f"[v][t]overlay=0:0:shortest=1,format=yuv420p[v2]")
        label = "[v2]"
    else:
        label = "[v]"

    # Exact length, CFR from zero. Padded then trimmed in the graph: with
    # -frames:v, an image-sequence input hitting EOF raced the encoder and
    # lost up to 8 frames; late starts / long last frames became concat
    # gaps (micro-stutters, cuts off the beat).
    graph += f";{label}{HOLD},trim=end_frame={frames},setpts=N/{FPS}/TB[out]"
    cmd += ["-filter_complex", graph, "-map", "[out]", "-an",
            "-c:v", "prores_videotoolbox", "-profile:v", "hq", out]
    run(cmd)
    return out


def sfx_mix(shots: list, cuts: list) -> tuple[list, str]:
    # Per-shot "sfx": [[name, offset_s, gain_db]] from edit/sfx.py, placed
    # at the shot's cut + offset (negative = lead in, e.g. a riser), summed
    # over the music [m] without normalizing, then limited -> [a].
    inputs, legs = [], []
    for k, shot in enumerate(shots):
        for name, offset, gain in shot.get("sfx", []):
            at = max(0.0, cuts[k] / FPS + offset)
            n = 2 + len(legs)
            inputs += ["-i", SFX / f"{name}.wav"]
            ms = round(at * 1000)
            legs.append(f"[{n}:a]adelay={ms}|{ms},volume={gain}dB[s{len(legs)}]")
    if not legs:
        return [], "[m]anull[a]"
    mix = "".join(f"[s{j}]" for j in range(len(legs)))
    graph = ";".join(legs) + (f";[m]{mix}amix=inputs={len(legs) + 1}:normalize=0:"
                              f"duration=first,alimiter=limit=0.95[a]")
    return inputs, graph


def main() -> None:
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    edl_path = pathlib.Path(sys.argv[1])
    edl = json.loads(edl_path.read_text())
    out_dir = REEL / "out" / edl_path.stem
    work = out_dir / "work"
    only = {int(k) for k in sys.argv[2].split(",")} if len(sys.argv) == 3 else None
    if only is None:
        shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True, exist_ok=True)
    accent = edl.get("accent", "#7aa2f7")

    # Frame counts from cumulative cut times: each cut lands on the nearest
    # frame of its beat, so rounding never accumulates (a beat at 128 BPM
    # is 28.125 frames at 60fps).
    shots = edl["shots"]
    cuts, t = [0], 0.0
    for s in shots:
        t += s["dur"]
        cuts.append(round(t * FPS))
    segs = []
    for k, s in enumerate(shots):
        seg = work / f"seg{k:03d}.mov"
        # Optional 2nd arg "3,7": re-render only those shots, reuse the rest.
        if only is None or k in only or not seg.exists():
            seg = render_shot(k, s, cuts[k + 1] - cuts[k], work, accent)
        segs.append(seg)
    listing = work / "concat.txt"
    listing.write_text("".join(f"file '{s}'\n" for s in segs))
    total = cuts[-1] / FPS

    # Music bed: from music_in, cut (short fade) at music_out so the end
    # card plays in silence.
    music = REEL / "music" / edl["music"]
    music_out = edl.get("music_out", total)
    master = out_dir / "reel-4k.mp4"
    sfx_inputs, sfx_graph = sfx_mix(shots, cuts)
    run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", listing,
         "-ss", edl.get("music_in", 0), "-i", music, *sfx_inputs,
         "-filter_complex",
         f"[1:a]afade=out:st={music_out - MUSIC_TAIL}:d={MUSIC_TAIL},apad[m];{sfx_graph}",
         "-map", "0:v", "-map", "[a]", "-t", total,
         "-c:v", "hevc_videotoolbox", "-q:v", 72, "-tag:v", "hvc1",
         "-c:a", "aac", "-b:a", "320k", "-movflags", "+faststart", master])

    # Share copy: 1080p60 H.264, plays everywhere (and uploads to X).
    share = out_dir / "reel-1080.mp4"
    run(["ffmpeg", "-v", "error", "-y", "-i", master,
         "-vf", "scale=1920:1080:flags=lanczos", "-c:v", "h264_videotoolbox",
         "-b:v", "16M", "-c:a", "copy", "-movflags", "+faststart", share])
    print(master)
    print(share)


if __name__ == "__main__":
    main()
