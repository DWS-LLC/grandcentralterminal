"""GCT as an airframe: the hero CG for the flight-test cut (after X-BAT /
Fury / Figure 03). Headless:

    blender -b --python demo/edit/airframe.py -- <shot|all> [--preview] [--fast]

--fast renders 2560x1440 @ 24 samples (~2.5x quicker); cut.py scales it
up to 4K, and callout tracks are always in 3840x2160 pixels.

         ┌───────────────────────── canvas slab (anodized, chamfered) ──┐
         │ ┌───────────┐ ┌──────┐   pane bays: real panes under glass   │
         │ │   nvim    │ │ btop │   engraved panel lines + markings     │
         │ └───────────┘ └──────┘                                       │
         └──────────────┬───────────────────────────────────────────────┘
                        │ PTY conduits (x-ray only)
                    [ GCTD core ]

Shots (dark hangar, haze, sweeping strip lights):
    reveal     a light strip finds the chamfer, low dolly
    macro      100mm skim across the bays and markings
    top        overhead pull-back: the whole canvas lit
    xray       the slab ghosts out; core + conduits pulse to every pane
    formation  three host airframes slide into formation, linked

Each shot renders PNG frames to ~/Movies/GCT Reel/work/airframe/<shot>/,
encodes render/air-<shot>.mov (ProRes), and writes tracks-<shot>.json:
per-frame pixel positions of named anchors, for edit/titles.py callouts.
"""

import json
import math
import pathlib
import subprocess
import sys

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Vector

REEL = pathlib.Path.home() / "Movies/GCT Reel"
WORK = REEL / "work/airframe"
PANE_DIR = REEL / "work/stack"          # pane crops from edit/stack.py
FPS = 60
W, H = 3840, 2160

SLAB = (16.0, 9.0, 0.5)                 # canvas airframe, units
STILL = (6400, 3600)                    # rice still the bays are laid out from
BAY_DEPTH = 0.12
INSET = 0.86                            # bays use 86% of the top face
FONT = "/Library/Fonts/SF-Pro-Display-Semibold.otf"
MONO = str(pathlib.Path.home() / "Library/Fonts/JetBrainsMonoNerdFontMono-Medium.ttf")
CYAN = (0.05, 0.62, 1.0)               # saturated: AgX bleaches bright cyan
HOSTS = {                                # formation: name -> (offset, accent)
    "build-01": ((-13.0, -7.0, 1.0), (0.96, 0.62, 0.04)),
    "gpu-02": ((13.0, -7.0, 1.0), (0.20, 0.83, 0.60)),
    "edge-03": ((0.0, -14.5, 2.0), (0.93, 0.29, 0.60)),
}
# Pane crops in the rice still (6400x3600): name -> x, y, w, h.
PANES = {
    "nvim": (548, 192, 3128, 2296),
    "btop": (3764, 1236, 2088, 1252),
    "bonsai": (548, 2572, 1540, 884),
    "clock": (2176, 2572, 1500, 884),
    "pipes": (3764, 2572, 2088, 884),
}
SHOTS = {"reveal": 5.0, "macro": 4.0, "top": 4.0, "xray": 6.0, "formation": 5.0}


# --- Scene ---------------------------------------------------------------------
FAST_PERCENT, FAST_SAMPLES = 67, 24


def reset(seconds: float, preview: bool, fast: bool = False) -> bpy.types.Scene:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x, scene.render.resolution_y = W, H
    scene.render.resolution_percentage = 25 if preview else FAST_PERCENT if fast else 100
    scene.render.fps = FPS
    scene.frame_start, scene.frame_end = 1, int(seconds * FPS)
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "AgX - High Contrast"
    eevee = scene.eevee
    eevee.taa_render_samples = 16 if preview else FAST_SAMPLES if fast else 32
    eevee.use_raytracing = True
    eevee.volumetric_tile_size = "4"
    eevee.use_volumetric_shadows = True
    scene.render.use_motion_blur = True     # speed reads as weight
    scene.render.motion_blur_shutter = 0.5

    # Black hangar with a thin haze, so strip lights read as beams.
    world = bpy.data.worlds.new("hangar")
    world.use_nodes = True
    nodes, links = world.node_tree.nodes, world.node_tree.links
    nodes["Background"].inputs[0].default_value = (0.002, 0.0022, 0.003, 1)
    haze = nodes.new("ShaderNodeVolumeScatter")
    haze.inputs["Density"].default_value = 0.012
    links.new(haze.outputs[0], nodes["World Output"].inputs["Volume"])
    scene.world = world
    return scene


def mat(name: str, color=(0.02, 0.02, 0.022), metal=1.0, rough=0.32,
        emit=None, strength=0.0) -> bpy.types.Material:
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Metallic"].default_value = metal
    b.inputs["Roughness"].default_value = rough
    if emit:
        b.inputs["Emission Color"].default_value = (*emit, 1)
        b.inputs["Emission Strength"].default_value = strength
    return m


def screen_mat(name: str, image: pathlib.Path) -> bpy.types.Material:
    # A lit display: emissive pane texture, no gloss (glass sits above).
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nodes, links = m.node_tree.nodes, m.node_tree.links
    b = nodes["Principled BSDF"]
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(str(image))
    links.new(tex.outputs["Color"], b.inputs["Emission Color"])
    b.inputs["Base Color"].default_value = (0, 0, 0, 1)
    b.inputs["Emission Strength"].default_value = 2.2
    b.inputs["Roughness"].default_value = 1.0
    b.inputs["Specular IOR Level"].default_value = 0.0
    return m


def glass_mat() -> bpy.types.Material:
    # Cover glass: clear, faint reflections, catches the strip lights.
    m = bpy.data.materials.new("glass")
    m.use_nodes = True
    nodes, links = m.node_tree.nodes, m.node_tree.links
    b = nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (0, 0, 0, 1)
    b.inputs["Roughness"].default_value = 0.04
    b.inputs["Alpha"].default_value = 0.18
    m.surface_render_method = "BLENDED"
    return m


def box(name: str, size, loc=(0, 0, 0), material=None, bevel=0.0) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    ob = bpy.context.object
    ob.name = name
    ob.scale = size
    bpy.ops.object.transform_apply(scale=True)
    if material:
        ob.data.materials.append(material)
    if bevel:
        mod = ob.modifiers.new("chamfer", "BEVEL")
        mod.width, mod.segments, mod.limit_method = bevel, 3, "ANGLE"
    return ob


def plane(name: str, w: float, h: float, loc, material) -> bpy.types.Object:
    bpy.ops.mesh.primitive_plane_add(size=1, location=loc)
    ob = bpy.context.object
    ob.name = name
    ob.scale = (w, h, 1)
    bpy.ops.object.transform_apply(scale=True)
    ob.data.materials.append(material)
    return ob


def label(text: str, loc, size: float, material, font=FONT, rot=0.0) -> bpy.types.Object:
    # Printed airframe marking, flush on the skin.
    curve = bpy.data.curves.new(text, "FONT")
    curve.body = text
    curve.size = size
    curve.font = bpy.data.fonts.load(font)
    ob = bpy.data.objects.new(text, curve)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    ob.rotation_euler.z = rot
    ob.data.materials.append(material)
    return ob


def anchor(name: str, loc, parent=None) -> bpy.types.Object:
    e = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(e)
    e.location = loc
    e.parent = parent
    return e


# --- Airframe ------------------------------------------------------------------
def bay_rects(sx: float, sy: float) -> dict:
    # Pane bays laid out like the still, scaled to the slab top.
    out = {}
    for name, (x, y, w, h) in PANES.items():
        bw, bh = w / STILL[0] * sx * INSET, h / STILL[1] * sy * INSET
        cx = ((x + w / 2) / STILL[0] - 0.5) * sx * INSET
        cy = (0.5 - (y + h / 2) / STILL[1]) * sy * INSET
        out[name] = (cx, cy, bw, bh)
    return out


def airframe(tag: str, origin, scale: float, accent=None) -> dict:
    # One canvas airframe; returns its parts for shots and callouts.
    sx, sy, sz = (d * scale for d in SLAB)
    root = anchor(f"{tag}-root", origin)
    skin = mat(f"{tag}-skin", color=(0.018, 0.019, 0.022), rough=0.3)
    slab = box(f"{tag}-slab", (sx, sy, sz), material=skin, bevel=0.09 * scale)
    slab.parent = root

    # Bays: boolean cutters, then a screen + cover glass in each.
    glass = glass_mat()
    screens = []
    for name, (cx, cy, bw, bh) in bay_rects(sx, sy).items():
        cutter = box(f"{tag}-cut-{name}", (bw, bh, BAY_DEPTH * 2 * scale),
                     loc=(cx, cy, sz / 2))
        cutter.display_type = "WIRE"
        cutter.hide_render = True
        mod = slab.modifiers.new(f"bay-{name}", "BOOLEAN")
        mod.object, mod.operation, mod.solver = cutter, "DIFFERENCE", "EXACT"
        cutter.parent = root
        z = sz / 2 - BAY_DEPTH * scale
        s = plane(f"{tag}-screen-{name}", bw * 0.985, bh * 0.985, (cx, cy, z + 0.004),
                  screen_mat(f"{tag}-scr-{name}", PANE_DIR / f"pane-{name}.png"))
        g = plane(f"{tag}-glass-{name}", bw, bh, (cx, cy, sz / 2 - 0.01 * scale), glass)
        for ob in (s, g):
            ob.parent = root
        screens.append(s)
    # Bevel after the bays so their rims are chamfered too.
    slab.modifiers.move(0, len(slab.modifiers) - 1)

    # Panel lines + markings, printed in a light grey.
    paint = mat(f"{tag}-paint", color=(0.55, 0.56, 0.58), metal=0.0, rough=0.6)
    top = sz / 2 + 0.002
    for x in (-sx * 0.47, sx * 0.47):
        line = plane(f"{tag}-line{x:.0f}", 0.012 * scale, sy * 0.9, (x, 0, top), paint)
        line.parent = root
    marks = [
        ("GCT-1", (-sx * 0.45, sy * 0.455, top), 0.32),
        ("GRAND CENTRAL TERMINAL", (-sx * 0.45, -sy * 0.475, top), 0.16),
        ("PTY BUS 01-05  ·  DO NOT DETACH", (sx * 0.12, -sy * 0.475, top), 0.13),
    ]
    if accent:
        marks = [(tag.upper(), (-sx * 0.45, sy * 0.455, top), 0.32)]
    for text, loc, size in marks:
        m = label(text, loc, size * scale, paint, font=MONO if "PTY" in text else FONT)
        m.parent = root
    if accent:
        # Host stripe along the leading edge, in the host's canvas color.
        stripe = box(f"{tag}-stripe", (sx * 0.98, 0.05 * scale, 0.02 * scale),
                     loc=(0, -sy / 2 - 0.01, 0),
                     material=mat(f"{tag}-acc", color=accent, metal=0.0, emit=accent, strength=6))
        stripe.parent = root

    # GCTD core under the slab, with a conduit to every bay (x-ray only).
    core_mat = mat(f"{tag}-core", color=(0.01, 0.01, 0.01), emit=CYAN, strength=0.0)
    core = box(f"{tag}-core", (2.6 * scale, 1.4 * scale, 0.5 * scale),
               loc=(0, 0, -sz / 2 - 0.45 * scale), material=core_mat, bevel=0.05)
    core.parent = root
    conduit_mat = mat(f"{tag}-conduit", color=(0.01, 0.01, 0.01), emit=CYAN, strength=0.0)
    conduits = []
    for name, (cx, cy, _, _) in bay_rects(sx, sy).items():
        c = conduit(f"{tag}-pty-{name}", Vector((0, 0, -sz / 2 - 0.3 * scale)),
                    Vector((cx, cy, -0.05)), 0.035 * scale, conduit_mat)
        c.parent = root
        conduits.append(c)

    root.location = origin
    return {"root": root, "slab": slab, "skin": skin, "core": core, "core_mat": core_mat,
            "conduit_mat": conduit_mat, "screens": screens, "size": (sx, sy, sz)}


def conduit(name: str, a: Vector, b: Vector, radius: float, material) -> bpy.types.Object:
    curve = bpy.data.curves.new(name, "CURVE")
    curve.dimensions = "3D"
    curve.bevel_depth = radius
    spline = curve.splines.new("BEZIER")
    spline.bezier_points.add(1)
    p0, p1 = spline.bezier_points
    p0.co, p1.co = a, b
    p0.handle_right = a + Vector((0, 0, -0.6))
    p0.handle_left = a
    p1.handle_left = b + Vector((0, 0, -1.2))
    p1.handle_right = b
    ob = bpy.data.objects.new(name, curve)
    bpy.context.scene.collection.objects.link(ob)
    ob.data.materials.append(material)
    return ob


def floor() -> None:
    # Dark polished concrete: soft reflections of the strip lights.
    plane("floor", 400, 400, (0, 0, -1.6), mat("floor", color=(0.012, 0.012, 0.013),
                                                  metal=0.0, rough=0.22))


def strip(name: str, loc, size=(30.0, 0.35), energy=900.0, rot=(0, 0, 0)) -> bpy.types.Object:
    light = bpy.data.lights.new(name, "AREA")
    light.shape, light.size, light.size_y = "RECTANGLE", size[0], size[1]
    light.energy = energy
    light.color = (0.9, 0.95, 1.0)
    ob = bpy.data.objects.new(name, light)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    ob.rotation_euler = rot
    return ob


def camera(lens: float, fstop: float = 0.0, focus=None) -> bpy.types.Object:
    data = bpy.data.cameras.new("cam")
    data.lens = lens
    data.sensor_width = 36
    if fstop:
        data.dof.use_dof = True
        data.dof.aperture_fstop = fstop
        data.dof.focus_object = focus
    cam = bpy.data.objects.new("cam", data)
    bpy.context.scene.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    return cam


def key(ob, path: str, frames_values: list, index: int = -1) -> None:
    # New keys default to auto-clamped Bezier: eased, no snaps.
    for f, v in frames_values:
        setattr(ob, path, v) if index < 0 else getattr(ob, path).__setitem__(index, v)
        ob.keyframe_insert(path, index=index, frame=f)


# --- Shots ---------------------------------------------------------------------
def shot_reveal(scene, af: dict) -> dict:
    # Black; a strip light slides along the hangar roof and finds the
    # chamfer; camera low at the leading corner, creeping forward.
    end = scene.frame_end
    light = strip("sweep", (-30, -12, 7), size=(0.5, 16), energy=2200,
                  rot=(math.radians(-35), 0, 0))
    key(light, "location", [(1, (-34, -12, 7)), (end, (22, -12, 7))])
    rim = strip("rim", (0, 14, 4), size=(24, 0.3), energy=500, rot=(math.radians(-70), 0, 0))
    key(rim.data, "energy", [(1, 0.0), (int(end * 0.45), 0.0), (end, 500.0)])
    power_on(af["screens"], start=int(end * 0.58))
    cam = camera(60)
    focus = anchor("look", (1, -1, 0))
    cam.constraints.new("TRACK_TO").target = focus
    key(cam, "location", [(1, (-14, -17, 4.6)), (end, (-11, -14, 3.6))])
    return {}


def power_on(screens: list, start: int, stagger: int = 9) -> None:
    # Boot sequence: each pane is dark, then flickers on, one after another.
    for k, ob in enumerate(screens):
        strength = ob.material_slots[0].material.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"]
        f = start + k * stagger
        for frame, v in ((1, 0.0), (f, 0.0), (f + 2, 2.6), (f + 4, 0.4), (f + 7, 2.2)):
            strength.default_value = v
            strength.keyframe_insert("default_value", frame=frame)


def shot_macro(scene, af: dict) -> dict:
    # Skim the skin at 100mm: bay rims, glass glints, the GCT-1 marking.
    end = scene.frame_end
    sx, sy, sz = af["size"]
    strip("top", (0, 0, 10), size=(30, 1.2), energy=500)
    glint = strip("glint", (-12, -6, 5), size=(14, 0.25), energy=900,
                  rot=(math.radians(55), 0, math.radians(-30)))
    key(glint, "location", [(1, (-12, -6, 5)), (end, (6, -6, 5))])
    focus = anchor("focus", (-sx * 0.3, sy * 0.36, sz / 2))
    key(focus, "location", [(1, (-sx * 0.42, sy * 0.44, sz / 2)), (end, (-sx * 0.22, sy * 0.18, sz / 2))])
    cam = camera(100, fstop=2.0, focus=focus)
    cam.constraints.new("TRACK_TO").target = focus
    key(cam, "location", [(1, (-sx * 0.55, sy * 0.05, 1.4)), (end, (-sx * 0.38, -sy * 0.12, 1.3))])
    return {}


def shot_top(scene, af: dict) -> dict:
    # Overhead: starts tight on the screens, pulls back to the whole slab.
    end = scene.frame_end
    strip("top", (0, -3, 14), size=(30, 2.0), energy=700)
    strip("rimL", (-14, 0, 3), size=(0.4, 14), energy=300)
    cam = camera(50)
    look = anchor("look", (0, 0, 0))
    cam.constraints.new("TRACK_TO").target = look
    key(cam, "location", [(1, (0.6, -2.0, 8.0)), (end, (1.2, -6.5, 21.0))])
    return {}


def shot_xray(scene, af: dict) -> dict:
    # Skin ghosts to an x-ray; the GCTD core lights, conduits pulse up to
    # every pane. Anchors feed the callouts.
    end = scene.frame_end
    sx, sy, sz = af["size"]
    strip("top", (0, 0, 12), size=(30, 1.5), energy=500)
    strip("rim", (0, 14, 4), size=(24, 0.3), energy=400, rot=(math.radians(-70), 0, 0))
    ghost_skin(af["skin"], scene, start=int(end * 0.12), length=int(end * 0.25))
    t0 = int(end * 0.30)
    for m, peak in ((af["core_mat"], 2.2), (af["conduit_mat"], 1.4)):
        b = m.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"]
        b.default_value = 0.0
        b.keyframe_insert("default_value", frame=t0)
        b.default_value = peak
        b.keyframe_insert("default_value", frame=t0 + 40)
    cam = camera(60)
    look = anchor("look", (0, 0, -0.4))
    cam.constraints.new("TRACK_TO").target = look
    key(cam, "location", [(1, (-17, -16, 9)), (end, (-12, -18, 6.5))])
    bays = bay_rects(sx, sy)
    return {
        "core": anchor("a-core", (1.3, 0, -sz / 2 - 0.45)),
        "pty": anchor("a-pty", (bays["btop"][0] * 0.55, bays["btop"][1] * 0.55, -sz / 2 - 0.25)),
        "screen": anchor("a-screen", (bays["nvim"][0], bays["nvim"][1] + bays["nvim"][3] * 0.3, 0)),
        "edge": anchor("a-edge", (sx / 2, -sy / 2, 0)),
    }


def ghost_skin(skin, scene, start: int, length: int) -> None:
    # Mix the anodized skin into a fresnel-edged x-ray (X-BAT's cutaway).
    nodes, links = skin.node_tree.nodes, skin.node_tree.links
    out = nodes["Material Output"]
    bsdf = nodes["Principled BSDF"]
    clear = nodes.new("ShaderNodeBsdfTransparent")
    edge = nodes.new("ShaderNodeEmission")
    edge.inputs["Color"].default_value = (0.75, 0.82, 0.9, 1)
    edge.inputs["Strength"].default_value = 0.9
    fres = nodes.new("ShaderNodeLayerWeight")
    fres.inputs["Blend"].default_value = 0.5
    rim = nodes.new("ShaderNodeMath")
    rim.operation, rim.inputs[1].default_value = "POWER", 8.0
    links.new(fres.outputs["Facing"], rim.inputs[0])
    xray = nodes.new("ShaderNodeMixShader")
    links.new(rim.outputs[0], xray.inputs["Fac"])
    links.new(clear.outputs[0], xray.inputs[1])
    links.new(edge.outputs[0], xray.inputs[2])
    mix = nodes.new("ShaderNodeMixShader")
    links.new(bsdf.outputs[0], mix.inputs[1])
    links.new(xray.outputs[0], mix.inputs[2])
    links.new(mix.outputs[0], out.inputs["Surface"])
    skin.surface_render_method = "BLENDED"
    fac = mix.inputs["Fac"]
    fac.default_value = 0.0
    fac.keyframe_insert("default_value", frame=start)
    fac.default_value = 1.0
    fac.keyframe_insert("default_value", frame=start + length)


def shot_formation(scene, af: dict) -> dict:
    # Host airframes slide in from the dark and hold station; their
    # links to the lead light up as they lock.
    end = scene.frame_end
    strip("top", (0, -8, 16), size=(60, 4.0), energy=6000)
    strip("front", (0, -30, 9), size=(60, 0.6), energy=2500, rot=(math.radians(60), 0, 0))
    strip("rim", (0, 20, 5), size=(60, 0.4), energy=1200, rot=(math.radians(-70), 0, 0))
    anchors = {"lead": anchor("a-lead", (0, 0, 0.4))}
    for k, (name, (off, accent)) in enumerate(HOSTS.items()):
        host = airframe(name, (0, 0, 0), 0.6, accent=accent)
        root = host["root"]
        far = Vector(off) + Vector((0, -26, -4))
        lock = int(end * (0.35 + 0.12 * k))
        key(root, "location", [(1, tuple(far)), (lock, off)])
        anchors[name] = anchor(f"a-{name}", (0, 0, 0.5), parent=root)
    cam = camera(32)
    look = anchor("look", (0, -6.5, 0))
    cam.constraints.new("TRACK_TO").target = look
    key(cam, "location", [(1, (-8, -44, 19)), (end, (6, -41, 15))])
    return anchors


# --- Render --------------------------------------------------------------------
def tracks(scene, anchors: dict) -> dict:
    # Pixel position (top-left origin, 3840x2160) of every anchor, per frame.
    out = {name: [] for name in anchors}
    for f in range(scene.frame_start, scene.frame_end + 1):
        scene.frame_set(f)
        for name, ob in anchors.items():
            p = world_to_camera_view(scene, scene.camera, ob.matrix_world.translation)
            out[name].append([round(p.x * W, 1), round((1 - p.y) * H, 1)])
    return out


def build(shot: str, preview: bool, fast: bool = False) -> None:
    scene = reset(SHOTS[shot], preview, fast)
    floor()
    af = airframe("gct", (0, 0, 0), 1.0)
    anchors = globals()[f"shot_{shot}"](scene, af)

    out = WORK / shot
    out.mkdir(parents=True, exist_ok=True)
    (WORK / f"tracks-{shot}.json").write_text(json.dumps(tracks(scene, anchors)))
    if preview:
        # Four stills across the shot, quarter res.
        for f in (1, scene.frame_end // 3, 2 * scene.frame_end // 3, scene.frame_end):
            scene.frame_set(f)
            scene.render.filepath = str(out / f"p{f:04d}.png")
            bpy.ops.render.render(write_still=True)
        return

    scene.render.filepath = str(out / "f")
    scene.render.image_settings.file_format = "PNG"
    scene.render.use_overwrite = False   # resumable
    bpy.ops.render.render(animation=True)
    mov = REEL / "render" / f"air-{shot}.mov"
    mov.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-framerate", str(FPS), "-start_number", "1",
                    "-i", str(out / "f%04d.png"), "-c:v", "prores_videotoolbox",
                    "-profile:v", "hq", "-pix_fmt", "yuv422p10le", str(mov)], check=True)
    print(mov)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if not argv:
        sys.exit(__doc__)
    preview, fast = "--preview" in argv, "--fast" in argv
    names = list(SHOTS) if argv[0] == "all" else [argv[0]]
    for name in names:
        build(name, preview, fast)
