"""Specs for the End crystal, the conduit and the enchanting table's book.

Three mesh entities that are neither mobs nor blocks, each a model atlas
(atlas.py, stems/mineclonia.mobs.txt). Like world_objects.py this writes a
full grid per stem from face rectangles and a few colour rules, with the
materials one table per object below. How each is drawn:

  crystal  mcl_end:crystal draws mcl_end_crystal.png on mcl_end_crystal.b3d
           (one mesh, one brush, visual_size 6, so a texel is about a
           sixteenth of a node), looping frames 0 to 120 at 25 a second;
           the animation turns the boxes and changes no texture, and the
           beam is an entity of its own. Three nested cubes: two glass
           cubes share the six faces at (0, 0)..(64, 32), drawn only round
           their edges, the middle transparent; the core cube is the six
           faces at (64, 0)..(128, 32). The bedrock base at (0, 32)..(96,
           64) is Minecraft's plinth, which this model never draws.
  conduit  mcl_conduits:conduit draws mcl_conduit_conduit.png on the same
           mcl_end_crystal.b3d (visual_size 4), frames 0 to 120 at 3 a
           second, so the same layout: the two outer cubes are the
           prismarine cage, a frame with bright cyan crystal in it, and the
           core is a shell of prismarine with an eye drawn on each face.
           The placed node (mcl_conduit_conduit_node) is a tile of its own.
  book     mcl_enchanting:book draws mcl_enchanting_book_entity.png on
           mcl_enchanting_book.b3d's five meshes (the textures list names
           the image five times, visual_size 12.5), animated open and
           shut by mcl_enchanting.set_book_animation. The covers are
           single quads, (6, 0)..(12, 10) and (22, 0)..(28, 10), the spine
           (12, 0)..(14, 10). Each page block is a box whose edges stretch
           one texel row; the right block reads its pages at (7, 11)..(12,
           19), the left one (1, 11)..(6, 19), which the art leaves
           transparent, so it draws nothing. The rest of the art (the
           covers' Minecraft box sides, the pages at (13, 10) and (24, 10))
           is islands no face uses.

The house style settled with the owner: per texel shade steps shallow
inside a material, main surfaces near the top of the range, each part its
own material, crisp plateaus on the texel grid, metal bright, glass and
crystal smooth with a little reflectance, glow from the art's own bright
texels.

    python3 tools/pbr/pbr_author/end_objects.py            # write every spec
    python3 tools/pbr/pbr_author/end_objects.py --check    # exit 1 if any differs
    python3 tools/pbr/pbr_author/end_objects.py book       # one object

MODELS says which model and brush each stem is drawn with, for atlas.py's
--model and --brush until the stem is in the list.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import atlas  # noqa: E402
import lib  # noqa: E402
import mob_families as mf  # noqa: E402

GAME = "mineclonia"

MODELS = {
    "mcl_end_crystal": ("mcl_end_crystal.b3d", 0),
    "mcl_conduit_conduit": ("mcl_end_crystal.b3d", 0),
    "mcl_enchanting_book_entity": ("mcl_enchanting_book.b3d", 0),
}

# Every stem's keys: world_objects.py's, the box edge bevelled.
HEAD = {"texel_px": 16, "strength": 24.0, "chamfer": 2, "face_edge": "bevel", "bevel_px": 3,
        "bevel_depth": 0.07, "micro": "none"}

# The glass and cage cubes are drawn only round their edges, the middle
# transparent. Built as overlays, as the shulkers are, the holes stand at
# the edges' top, so the edges do not chamfer down into them: they did, and
# drew a bright line round the inside of every frame.
HOLES = {"overlay": True, "surface": 0.95}

# --- helpers -----------------------------------------------------------------------


def texels(src):
    """(x, y, hex, h, s, luminance) for every drawn texel."""
    q = np.clip(np.round(src[..., :3] * 255.0), 0, 255).astype(int)
    for y, x in zip(*np.nonzero(src[..., 3] >= 0.5)):
        rgb = src[y, x, :3]
        h, s, v = mf.hsv(rgb)
        yield int(x), int(y), "#%02x%02x%02x" % tuple(q[y, x]), h, s, mf.lum(rgb)


def spec_of(mat, materials, src, cls, extra=None):
    out = dict(HEAD)
    out["class"] = cls
    out.update(extra or {})
    spec = mf.to_spec(mat, materials, None, src)
    out.update({k: v for k, v in spec.items() if k in ("materials", "grid", "legend")})
    return out


def face_rects(stem):
    model, brush = MODELS[stem]
    src = lib.load_source(stem, GAME)
    h, w = src.shape[:2]
    return [r for r, _ in atlas.faces(model, brush, w, h, GAME)]


def on_rim(x, y, rects):
    """True on a texel in the outermost ring of a face rectangle."""
    for x0, y0, x1, y1 in rects:
        if x0 <= x < x1 and y0 <= y < y1:
            return x in (x0, x1 - 1) or y in (y0, y1 - 1)
    return False


# --- the End crystal ------------------------------------------------------------------

# The glass cubes' edges: smooth glass, a little reflectance, lighter a
# shallow step higher (the art's white highlights stand over its lilac).
CRYSTAL_GLASS = {"mode": "shade", "base": 0.92, "span": 0.06, "levels": 2, "detail": 0.3,
                 "joints": False, "smooth": 0.92, "smooth_spread": 0.02, "f0": 0.05,
                 "micro": "glass", "micro_strength": 0.4}
# The core: a dark red crystal box, its drawn bevel kept by shade, smooth,
# glowing faintly by shade (emission_shade squares the shade's place in
# the span, so 0.6 comes to about 0.05 to 0.12 on the lighter texels).
CRYSTAL_CORE = {"mode": "shade", "base": 0.86, "span": 0.1, "levels": 3, "detail": 0.3,
                "joints": False, "smooth": 0.72, "smooth_spread": 0.03, "f0": 0.05,
                "micro": "glass", "micro_strength": 0.3, "emission": 0.6,
                "emission_shade": True}
# The glyphs on the core: the bright orange texels, flush with the core's
# top, glowing full.
CRYSTAL_GLYPH = {"mode": "flat", "base": 0.96, "span": 0.0, "micro": "none", "smooth": 0.75,
                 "smooth_spread": 0.0, "emission": 1.0}
# The bedrock plinth no face draws: stone by shade, its darkest sunk.
CRYSTAL_BASE = {"mode": "shade", "base": 0.7, "span": 0.25, "levels": 3, "detail": 0.3,
                "joints": True, "joint": 0.2, "smooth": 0.3, "smooth_spread": 0.04}


def crystal_specs():
    stem = "mcl_end_crystal"
    src = lib.load_source(stem, GAME)
    h, w = src.shape[:2]
    mat = np.full((h, w), "glass", dtype=object)
    for x, y, c, hh, s, L in texels(src):
        if y >= 32:
            m = "base"
        elif x >= 64:
            m = "glyph" if c == "#d67b5d" else "core"
        else:
            m = "glass"
        mat[y, x] = m
    mats = {"glass": CRYSTAL_GLASS, "core": CRYSTAL_CORE, "glyph": CRYSTAL_GLYPH,
            "base": CRYSTAL_BASE}
    return {stem: spec_of(mat, mats, src, "glass", HOLES)}


# --- the conduit ------------------------------------------------------------------------

# Prismarine, the cage's frame and the core's shell: stone by shade, a
# shallow step, a little polish.
CONDUIT_SHELL = {"mode": "shade", "base": 0.86, "span": 0.12, "levels": 3, "detail": 0.3,
                 "joints": False, "smooth": 0.55, "smooth_spread": 0.04, "micro": "none",
                 "wear": 0.06}
# The bright cyan crystal in the cage and the shell: smooth, a little
# reflectance, glowing faintly. A flat material's emission_shade follows
# its per texel rank, not its brightness, and left these near uniform
# cyans at a tenth of the glow asked for, so the glow is even.
CONDUIT_CRYSTAL = {"mode": "flat", "base": 0.97, "span": 0.0, "smooth": 0.88,
                   "smooth_spread": 0.0, "f0": 0.05, "micro": "glass", "micro_strength": 0.4,
                   "emission": 0.3}
# The eye on each face of the core, flat and flush with the shell's top:
# the bright cyan iris and the pale white glow, the dark green pupil is
# glossy and dark, the grey blue lid round it matte.
CONDUIT_IRIS = {"mode": "flat", "base": 0.97, "span": 0.0, "micro": "none", "smooth": 0.8,
                "smooth_spread": 0.0, "emission": 0.9}
CONDUIT_WHITE = {"mode": "flat", "base": 0.97, "span": 0.0, "micro": "none", "smooth": 0.6,
                 "smooth_spread": 0.0, "emission": 0.6}
CONDUIT_PUPIL = {"mode": "flat", "base": 0.96, "span": 0.0, "micro": "none", "smooth": 0.8,
                 "smooth_spread": 0.0}
CONDUIT_LID = {"mode": "flat", "base": 0.9, "span": 0.0, "micro": "none", "smooth": 0.4,
               "smooth_spread": 0.0}
# Where the eye is drawn inside each 16 texel face of the core.
EYE = (3, 5, 13, 13)


def conduit_specs():
    stem = "mcl_conduit_conduit"
    src = lib.load_source(stem, GAME)
    h, w = src.shape[:2]
    mat = np.full((h, w), "shell", dtype=object)
    for x, y, c, hh, s, L in texels(src):
        lx, ly = x % 16, y % 16
        eye = x >= 64 and EYE[0] <= lx < EYE[2] and EYE[1] <= ly < EYE[3]
        deg = hh * 360.0
        if eye and s > 0.75 and 120 <= deg <= 170 and L < 0.4:
            m = "pupil"
        elif eye and s < 0.3 and L >= 0.6:
            m = "white"
        elif s > 0.5 and L >= 0.55:
            m = "iris" if eye else "crystal"
        elif eye and 200 <= deg <= 240 and L < 0.4:
            m = "lid"
        else:
            m = "shell"
        mat[y, x] = m
    mats = {"shell": CONDUIT_SHELL, "crystal": CONDUIT_CRYSTAL, "iris": CONDUIT_IRIS,
            "white": CONDUIT_WHITE, "pupil": CONDUIT_PUPIL, "lid": CONDUIT_LID}
    return {stem: spec_of(mat, mats, src, "stone", HOLES)}


# --- the enchanting table's book ---------------------------------------------------------

# The cover's leather field: lighter a shallow step higher, pebble grain,
# stitched inside its edge where it meets the binding and the corners.
BOOK_LEATHER = {"mode": "shade", "base": 0.9, "span": 0.08, "levels": 2, "detail": 0.3,
                "joints": False, "smooth": 0.38, "smooth_spread": 0.03, "micro": "leather",
                "micro_strength": 0.5, "wear": 0.12,
                "stitch": {"inset": 0.22, "length": 0.36, "gap": 0.18, "width": 0.07,
                           "groove": 0.05, "depth": 0.03}}
# The lighter leather round each cover's edge, the board's binding: one
# height, a little proud of the field.
BOOK_BINDING = {"mode": "flat", "base": 0.96, "span": 0.0, "micro": "leather",
                "micro_strength": 0.6, "smooth": 0.42, "smooth_spread": 0.0, "wear": 0.12}
# The corners and the spine's bands: bright worn metal, proud.
BOOK_METAL = {"mode": "flat", "base": 1.0, "span": 0.0, "metal": True, "micro": "metal_worn",
              "smooth": 0.58, "smooth_spread": 0.0, "wear": 0.1}
# Pages: paper, one flat sheet near the top, matte, the fibre in the
# normal only. The page blocks' top, bottom and fore edges all stretch the
# art's row 11 (one texel across, five along, over a face about nine
# texels by one): with a shallow step per shade (span 0.05), the chamfer
# between row 11 and row 12 slid the stretched strip under parallax, and
# 3 of its 5 texels kept half their area at 60 degrees; flat, all 5 do.
BOOK_PAPER = {"mode": "flat", "base": 0.97, "span": 0.0, "smooth": 0.22, "smooth_spread": 0.0,
              "micro": "paper", "micro_strength": 1.0}
# The writing: ink on the page, a hair under it and a little less matte.
BOOK_INK = {"mode": "flat", "base": 0.95, "span": 0.0, "micro": "paper", "micro_strength": 0.6,
            "smooth": 0.32, "smooth_spread": 0.0}
INK = {"#684f45", "#96705d"}
BINDING = {"#6b4328", "#845332"}


def book_specs():
    stem = "mcl_enchanting_book_entity"
    src = lib.load_source(stem, GAME)
    h, w = src.shape[:2]
    rects = [r for r in face_rects(stem) if r[3] <= 10]
    mat = np.full((h, w), "leather", dtype=object)
    for x, y, c, hh, s, L in texels(src):
        if y >= 10:
            m = "ink" if c in INK else "paper"
        elif s < 0.15:
            m = "metal"
        elif c in BINDING and (on_rim(x, y, rects) or not any(
                x0 <= x < x1 for x0, y0, x1, y1 in rects)):
            m = "binding"
        else:
            m = "leather"
        mat[y, x] = m
    mats = {"leather": BOOK_LEATHER, "binding": BOOK_BINDING, "metal": BOOK_METAL,
            "paper": BOOK_PAPER, "ink": BOOK_INK}
    return {stem: spec_of(mat, mats, src, "wood")}


FAMILIES = {"crystal": crystal_specs, "conduit": conduit_specs, "book": book_specs}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check_only = "--check" in sys.argv
    stale = []
    for name in args or list(FAMILIES):
        for stem, spec in FAMILIES[name]().items():
            if not mf.write(stem, spec, check_only):
                stale.append(stem)
    for s in stale:
        print(("differs " if check_only else "wrote ") + s)
    if check_only and stale:
        sys.exit(1)


if __name__ == "__main__":
    main()
