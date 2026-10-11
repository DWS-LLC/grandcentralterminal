"""Exploded architecture shot, after Anduril's ArsenalOS layer stacks:

    blender -b --python demo/edit/stack.py -- <rice-still.png>

            ┌──────────────────────┐  CANVAS  grid + viewport, see-through
            └──────────────────────┘
                  ▲ explode
            ┌──────────────────────┐  PANES   real GCT panes (cropped from
            └──────────────────────┘          a 6400x3600 still), raised
                  ▲
            ┌──────────────────────┐  GCTD    one row per PTY it owns
            └──────────────────────┘

Light-grey studio, three frosted sheets that start stacked and pull apart
while the camera drifts. EEVEE, 3840x2160 @ 60fps, PNG frames, then
ffmpeg -> ~/Movies/GCT Reel/render/stack.mov (ProRes) for edit/cut.py.
"""

import math
import pathlib
import subprocess
import sys

import bpy

REEL = pathlib.Path.home() / "Movies/GCT Reel"
WORK = REEL / "work/stack"
OUT = REEL / "render/stack.mov"
FPS = 60
SECONDS = 7.5
W, H = 3840, 2160

SHEET_W, SHEET_H, SHEET_T = 8.0, 4.5, 0.035
GAP_START, GAP_END = 0.10, 1.75      # vertical spacing between sheets
EXPLODE = (0.6, 4.6)                 # seconds: ease from start to end gap
STUDIO = (0.80, 0.80, 0.79)          # light grey cyclorama
SHEET = (0.92, 0.92, 0.91)
INK = "#1d1d1f"
FONT = "/Library/Fonts/SF-Pro-Display-Semibold.otf"
MONO = str(pathlib.Path.home() / "Library/Fonts/JetBrainsMonoNerdFontMono-Medium.ttf")
TEX = 2048                           # sheet texture width (px)

# Pane crops in the rice still (6400x3600): name -> x, y, w, h.
PANES = {
    "nvim": (548, 192, 3128, 2296),
    "btop": (3764, 1236, 2088, 1252),
    "bonsai": (548, 2572, 1540, 884),
    "clock": (2176, 2572, 1500, 884),
    "pipes": (3764, 2572, 2088, 884),
}
# PTY rows on the daemon sheet: what each pane is running.
PTYS = ["zsh  ·  nvim", "zsh  ·  btop", "zsh  ·  cbonsai", "zsh  ·  tty-clock", "zsh  ·  pipes.sh"]


def magick(*args) -> None:
    subprocess.run(["magick", *map(str, args)], check=True)


# --- Textures ------------------------------------------------------------------
def tex_header(title: str, sub: str) -> list:
    # Sheet title top-left, like Anduril's "Bill of Materials".
    return ["-font", FONT, "-pointsize", 84, "-fill", INK, "-annotate", "+70+50", title,
            "-font", MONO, "-pointsize", 40, "-fill", "#3a3a3e", "-annotate", "+74+150", sub]


def tex_daemon(path: pathlib.Path) -> None:
    # One outlined row per PTY the daemon owns.
    th = int(TEX * SHEET_H / SHEET_W)
    rows = []
    for k, label in enumerate(PTYS):
        y = 250 + k * 160
        rows += ["-fill", "none", "-stroke", "#9a9aa0", "-strokewidth", 3,
                 "-draw", f"rectangle 70,{y} {TEX - 70},{y + 120}", "-stroke", "none",
                 "-fill", INK, "-font", MONO, "-pointsize", 44,
                 "-annotate", f"+110+{y + 36}", f"PTY {k + 1:02d}",
                 "-annotate", f"+420+{y + 36}", label,
                 "-fill", "#2e7d32", "-annotate", f"+{TEX - 360}+{y + 36}", "RUNNING"]
    magick("-size", f"{TEX}x{th}", f"xc:rgb({','.join(str(int(c * 255)) for c in SHEET)})",
           "-gravity", "NorthWest", *tex_header("GCTD", "one daemon owns every pty"), *rows, path)


def tex_panes(path: pathlib.Path) -> None:
    th = int(TEX * SHEET_H / SHEET_W)
    magick("-size", f"{TEX}x{th}", f"xc:rgb({','.join(str(int(c * 255)) for c in SHEET)})",
           "-gravity", "NorthWest", *tex_header("PANES", "libghostty  ·  gpu rendered"), path)


def tex_canvas(path: pathlib.Path) -> None:
    # See-through sheet: fine grid, a viewport rectangle, header.
    th = int(TEX * SHEET_H / SHEET_W)
    grid = []
    for x in range(0, TEX, 64):
        grid += ["-draw", f"line {x},0 {x},{th}"]
    for y in range(0, th, 64):
        grid += ["-draw", f"line 0,{y} {TEX},{y}"]
    # Grid drawn opaque, then faded via the alpha channel (stroke colours
    # with alpha came out opaque); no fill, or it hazes the dark panes.
    magick("-size", f"{TEX}x{th}", "xc:none", "-stroke", "#3a3a40", "-strokewidth", 2, *grid,
           "-channel", "A", "-evaluate", "multiply", 0.35, "+channel",
           "-stroke", INK, "-strokewidth", 6, "-fill", "none",
           "-draw", f"rectangle 420,260 {TEX - 420},{th - 260}", "-stroke", "none",
           "-gravity", "NorthWest", *tex_header("CANVAS", "infinite  ·  pan  ·  zoom"), path)


def tex_pane_crops(still: pathlib.Path) -> dict:
    out = {}
    for name, (x, y, w, h) in PANES.items():
        p = WORK / f"pane-{name}.png"
        magick(still, "-crop", f"{w}x{h}+{x}+{y}", "+repage", "-resize", "1600x1600>", p)
        out[name] = (p, w, h)
    return out


# --- Scene ---------------------------------------------------------------------
def reset() -> bpy.types.Scene:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x, scene.render.resolution_y = W, H
    scene.render.fps = FPS
    scene.frame_start, scene.frame_end = 1, int(SECONDS * FPS)
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "AgX - Medium High Contrast"
    scene.eevee.taa_render_samples = 32
    world = bpy.data.worlds.new("studio")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (*STUDIO, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.9
    scene.world = world
    return scene


def material(name: str, image: pathlib.Path | None = None, color=SHEET,
             emit: float = 0.0, alpha: bool = False) -> bpy.types.Material:
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nodes, links = m.node_tree.nodes, m.node_tree.links
    bsdf = nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.45
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    if image:
        tex = nodes.new("ShaderNodeTexImage")
        tex.image = bpy.data.images.load(str(image))
        tex.extension = "CLIP"
        links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        if alpha:
            # Explicit mix: Principled's own Alpha still let the sheet's
            # gloss haze dark panes behind it.
            clear = nodes.new("ShaderNodeBsdfTransparent")
            mix = nodes.new("ShaderNodeMixShader")
            links.new(tex.outputs["Alpha"], mix.inputs["Fac"])
            links.new(clear.outputs[0], mix.inputs[1])
            links.new(bsdf.outputs[0], mix.inputs[2])
            links.new(mix.outputs[0], nodes["Material Output"].inputs["Surface"])
        if emit:
            # Terminals are light sources: they read as screens, not prints.
            links.new(tex.outputs["Color"], bsdf.inputs["Emission Color"])
            bsdf.inputs["Emission Strength"].default_value = emit
            # Matte: glossy screens mirrored the grid sheet above them.
            bsdf.inputs["Roughness"].default_value = 0.9
            bsdf.inputs["Specular IOR Level"].default_value = 0.0
    if alpha:
        m.surface_render_method = "BLENDED"
    return m


def slab(name: str, w: float, h: float, t: float, mat) -> bpy.types.Object:
    # Thin box with its top face UV-mapped to the full texture.
    bpy.ops.mesh.primitive_cube_add(size=1)
    ob = bpy.context.object
    ob.name = name
    ob.scale = (w, h, t)
    bpy.ops.object.transform_apply(scale=True)
    ob.data.materials.append(mat)
    uv = ob.data.uv_layers.active.data
    for poly in ob.data.polygons:
        for li in poly.loop_indices:
            v = ob.data.vertices[ob.data.loops[li].vertex_index].co
            uv[li].uv = (v.x / w + 0.5, v.y / h + 0.5)
    bevel = ob.modifiers.new("bevel", "BEVEL")
    bevel.width, bevel.segments = 0.012, 3
    return ob


def plane(name: str, w: float, h: float, mat) -> bpy.types.Object:
    bpy.ops.mesh.primitive_plane_add(size=1)
    ob = bpy.context.object
    ob.name = name
    ob.scale = (w, h, 1)
    bpy.ops.object.transform_apply(scale=True)
    ob.data.materials.append(mat)
    return ob


def ease(t: float) -> float:
    # Smootherstep: no snap at either end of the explode.
    t = min(max(t, 0.0), 1.0)
    return t * t * t * (t * (t * 6 - 15) + 10)


def build(still: pathlib.Path) -> None:
    scene = reset()
    WORK.mkdir(parents=True, exist_ok=True)
    tex_daemon(WORK / "daemon.png")
    tex_panes(WORK / "panes.png")
    tex_canvas(WORK / "canvas.png")
    crops = tex_pane_crops(still)

    floor = plane("floor", 200, 200, material("floor", color=STUDIO))
    floor.location.z = -0.4

    daemon = slab("gctd", SHEET_W, SHEET_H, SHEET_T, material("gctd", WORK / "daemon.png"))
    panes = slab("panes", SHEET_W, SHEET_H, SHEET_T, material("panes", WORK / "panes.png"))
    canvas = plane("canvas", SHEET_W, SHEET_H, material("canvas", WORK / "canvas.png", alpha=True))
    canvas.visible_shadow = False   # see-through: it would grey the panes below

    # Panes ride on their sheet, laid out like the still (6400x3600 ->
    # the sheet, inset), lifted a hair so they cast a contact shadow.
    inset = 0.86
    for name, (path, w, h) in crops.items():
        x, y = PANES[name][0], PANES[name][1]
        pw, ph = w / 6400 * SHEET_W * inset, h / 3600 * SHEET_H * inset
        cx = ((x + w / 2) / 6400 - 0.5) * SHEET_W * inset
        cy = (0.5 - (y + h / 2) / 3600) * SHEET_H * inset - 0.1
        tile = slab(f"pane-{name}", pw, ph, 0.02, material(f"m-{name}", path, emit=1.2))
        tile.location = (cx, cy, SHEET_T / 2 + 0.03)
        tile.parent = panes

    sheets = [daemon, panes, canvas]
    for f in range(scene.frame_start, scene.frame_end + 1):
        t = (f / FPS - EXPLODE[0]) / (EXPLODE[1] - EXPLODE[0])
        gap = GAP_START + (GAP_END - GAP_START) * ease(t)
        for k, ob in enumerate(sheets):
            ob.location.z = k * gap
            ob.keyframe_insert("location", index=2, frame=f)

    # Long lens three-quarter view; drifts 18 degrees around the stack and
    # keeps the lower-left third clear for the headline.
    target = bpy.data.objects.new("target", None)
    scene.collection.objects.link(target)
    cam_data = bpy.data.cameras.new("cam")
    cam_data.lens = 70
    cam_data.shift_x, cam_data.shift_y = -0.12, -0.06
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    track = cam.constraints.new("TRACK_TO")
    track.target = target
    for f in range(scene.frame_start, scene.frame_end + 1, 5):
        s = (f - 1) / (scene.frame_end - 1)
        az = math.radians(-38 + 18 * s)
        el = math.radians(34 - 4 * s)
        dist = 26.5 - 3 * s
        z_mid = (GAP_START + (GAP_END - GAP_START) * ease((f / FPS - EXPLODE[0]) / 4.0))
        target.location = (0, 0, z_mid)
        target.keyframe_insert("location", frame=f)
        cam.location = (dist * math.cos(el) * math.sin(az), -dist * math.cos(el) * math.cos(az),
                        z_mid + dist * math.sin(el))
        cam.keyframe_insert("location", frame=f)

    # Soft studio light: a big key from upper left, a fill, sun for shadows.
    key = bpy.data.lights.new("key", "AREA")
    key.energy, key.size = 5000, 14
    key_ob = bpy.data.objects.new("key", key)
    key_ob.location = (-8, -6, 14)
    key_ob.rotation_euler = (math.radians(40), 0, math.radians(-50))
    scene.collection.objects.link(key_ob)
    sun = bpy.data.lights.new("sun", "SUN")
    sun.energy, sun.angle = 1.6, math.radians(12)
    sun_ob = bpy.data.objects.new("sun", sun)
    sun_ob.rotation_euler = (math.radians(25), math.radians(-15), 0)
    scene.collection.objects.link(sun_ob)


def render() -> None:
    scene = bpy.context.scene
    frames = WORK / "frames"
    frames.mkdir(exist_ok=True)
    scene.render.filepath = str(frames / "f")
    scene.render.use_overwrite = False   # resumable: frames on disk are kept
    scene.render.image_settings.file_format = "PNG"
    bpy.ops.render.render(animation=True)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-framerate", str(FPS), "-start_number", "1",
                    "-i", str(frames / "f%04d.png"), "-c:v", "prores_videotoolbox",
                    "-profile:v", "hq", "-pix_fmt", "yuv422p10le", str(OUT)], check=True)
    print(OUT)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if len(argv) != 1:
        sys.exit(__doc__)
    build(pathlib.Path(argv[0]).expanduser())
    render()
