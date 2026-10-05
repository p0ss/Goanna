"""Specs for objects drawn in the world that are neither mobs nor blocks.

Boats, minecarts, worn armour and the held and placed things (chests as
entities, shields, tridents, bows, frames, banners and the rest). Some are
model atlases drawn on an entity's mesh (atlas.py, stems/mineclonia.mobs.txt)
and some are tiles or flat item images drawn as a node or a wield mesh
(extrude.py, stems/mineclonia.txt). Like mob_families.py this writes a spec
per stem from a part map and a few colour rules, with the materials one
table per family below:

  boats      the boat and raft atlases (mcl_boats_texture_*), which every
             boat and chest boat of that wood draws on its hull; the chest
             of a chest boat is mcl_chests_normal on the second brush, the
             chest block's own stem. Planks with the block planks' grain
             (the "wood" kind at one block texel per art texel), their dark
             seams sunk a little, the dark iron fittings worn dark iron, the
             pale lashings rope.
  minecart   the cart body every minecart draws: riveted iron plates in
             the iron golem's manner around a box of planks. What a cart
             carries is drawn with the block's own images and maps.

The house style settled with the owner: per texel shade steps shallow
inside a material (0.1 to 0.18 of the range), main surfaces near the top
of the range, each part its own material, crisp plateaus on the texel grid,
no hard bevel on soft materials, metal bright, the art's colours untouched.

    python3 tools/pbr_author/world_objects.py            # write every spec
    python3 tools/pbr_author/world_objects.py --check    # exit 1 if any differs
    python3 tools/pbr_author/world_objects.py boats      # one family

MODELS says which model and brush each atlas stem is drawn with, for
atlas.py's --model and --brush until the stem is in the list.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import atlas  # noqa: E402
import lib  # noqa: E402
import mob_families as mf  # noqa: E402

GAME = "mineclonia"

# Every atlas stem's keys: the cow's, which the owner approved, with the
# box edge bevelled (hard materials: wood, iron, plate).
HEAD = {"texel_px": 16, "strength": 24.0, "chamfer": 2, "face_edge": "bevel", "bevel_px": 3,
        "bevel_depth": 0.07, "micro": "none"}

MODELS = {}

# --- materials -------------------------------------------------------------------

# Planks: lighter higher by a shallow step, the darkest shades (the seams
# between planks and round a panel) sunk as joints a quarter of the way
# down, the block planks' grain along each piece.
PLANK = {"mode": "shade", "base": 0.82, "span": 0.14, "levels": 3, "detail": 0.3, "joints": True,
         "joint": 0.12, "smooth": 0.32, "smooth_spread": 0.04, "micro": "wood",
         "micro_dir": "along", "micro_strength": 0.8, "wear": 0.08}
# The same wood on a narrow face (an oar's shaft, a gunwale's edge, three
# texels or fewer across): one height, so parallax at a grazing view does
# not slide one column of a two texel face over the other.
NARROW_PLANK = {"mode": "flat", "base": 0.96, "span": 0.0, "micro": "wood", "micro_dir": "along",
                "micro_strength": 0.8, "smooth": 0.32, "smooth_spread": 0.0, "wear": 0.08}
# Dark iron fittings: brackets, the gunwale's cap, an oar's tip. Dark iron
# is a dielectric (a near black metal texel is a black mirror).
FITTING = {"mode": "flat", "base": 0.97, "span": 0.0, "micro": "metal_worn", "smooth": 0.42,
           "smooth_spread": 0.0, "wear": 0.12}
# Rope lashings on an oar's grip and across a raft's canes.
LASHING = {"mode": "flat", "base": 0.98, "span": 0.0, "micro": "rope", "micro_dir": "along",
           "micro_strength": 0.8, "smooth": 0.18, "smooth_spread": 0.0, "scatter": 0.2}
# Obsidian: glassy volcanic glass, lighter higher by a shallow step, its
# purple specks a little smoother.
OBSIDIAN = {"mode": "shade", "base": 0.84, "span": 0.12, "levels": 3, "detail": 0.3,
            "joints": False, "smooth": 0.78, "smooth_spread": 0.04, "micro": "glass",
            "micro_strength": 0.6, "wear": 0.06}
NARROW_OBSIDIAN = {"mode": "flat", "base": 0.92, "span": 0.0, "smooth": 0.78,
                   "smooth_spread": 0.0, "micro": "glass", "micro_strength": 0.6, "wear": 0.06}

# --- helpers -------------------------------------------------------------------------


def spec_of(mat, materials, src, cls, extra=None):
    """A full grid spec: the first material is the grid's '.'."""
    spec = mf.to_spec(mat, materials, None, src)
    out = dict(HEAD)
    out["class"] = cls
    out.update(extra or {})
    for k in ("materials", "grid", "legend"):
        out[k] = spec[k]
    return out


def texels(src):
    """(x, y, h, s, luminance) for every drawn texel."""
    drawn = src[..., 3] >= 0.5
    for y, x in zip(*np.nonzero(drawn)):
        rgb = src[y, x, :3]
        h, s, v = mf.hsv(rgb)
        yield int(x), int(y), h, s, mf.lum(rgb)


def narrow_mask(model, brush, w, h, most=3):
    """True on the texels of every face the model draws at most this many
    texels across, unless a wider face also draws them."""
    m = np.zeros((h, w), bool)
    wide = np.zeros((h, w), bool)
    for (x0, y0, x1, y1), _ in atlas.faces(model, brush, w, h, GAME):
        if min(x1 - x0, y1 - y0) <= most:
            m[y0:y1, x0:x1] = True
        else:
            wide[y0:y1, x0:x1] = True
    return m & ~wide


# --- boats -----------------------------------------------------------------------------
# mcl_boats_boat.b3d: brush 0 the hull and oars (the boat atlas), brush 1 the
# chest (mcl_chests_normal or blank). mcl_boats_raft.b3d the same for the
# bamboo raft.

WOODS = ("acacia", "birch", "cherry_blossom", "dark_oak", "jungle", "mangrove", "oak",
         "pale_oak", "spruce")


def boat_specs():
    out = {}
    stems = ["mcl_boats_texture_%s_boat" % w for w in WOODS + ("bamboo", "obsidian")]
    # Every wooden boat is one layout. The rope on the oars' grips is where
    # the oak's pale texels are: pale oak's planks are as pale as rope.
    oak = lib.load_source("mcl_boats_texture_oak_boat", GAME)
    lashed = np.zeros(oak.shape[:2], bool)
    for x, y, hh, s, L in texels(oak):
        lashed[y, x] = s < 0.22 and L > 0.55
    for stem in stems:
        raft = "bamboo" in stem
        MODELS[stem] = ("mcl_boats_raft.b3d" if raft else "mcl_boats_boat.b3d", 0)
        src = lib.load_source(stem, GAME)
        h, w = src.shape[:2]
        narrow = narrow_mask(MODELS[stem][0], 0, w, h)
        if "obsidian" in stem:
            mat = np.where(narrow, "narrow", "obsidian").astype(object)
            out[stem] = spec_of(mat, {"obsidian": OBSIDIAN, "narrow": NARROW_OBSIDIAN}, src,
                                "stone")
            continue
        mat = np.full((h, w), "plank", dtype=object)
        for x, y, hh, s, L in texels(src):
            if s < 0.12 and L < 0.25:
                mat[y, x] = "fitting"
            elif s < 0.22 and L > 0.55 and (raft or lashed[y, x]):
                mat[y, x] = "lashing"
            elif narrow[y, x]:
                mat[y, x] = "narrow"
        out[stem] = spec_of(mat, {"plank": PLANK, "narrow": NARROW_PLANK, "fitting": FITTING,
                                  "lashing": LASHING},
                            src, "wood")
    return out


# --- minecarts -------------------------------------------------------------------------
# Every cart draws mcl_minecarts_minecart.png on the cart body, the last mesh
# of its model; what it carries is drawn with the block's own images
# (mcl_chests_normal, default_furnace_*, default_tnt_*, mcl_hoppers_*,
# jeija_commandblock_off), so their maps are the blocks'. The body is the
# planks of a box in a frame of riveted iron, every iron texel a plate as on
# the iron golem: a crisp shallow bevel, a small tilt and step per plate,
# scratches, a dent here and there, rivet heads along each piece's border.

PLATE_MIX = {"layers": [
    {"kind": "plate", "params": {"step": 0.12, "tilt": 0.2}},
    {"kind": "scratches", "strength": 0.3, "swing": 0.6,
     "params": {"count": 0.35, "length": 0.4, "width": 0.03}},
    {"kind": "dents", "strength": 0.6, "params": {"density": 0.25, "second": 0, "radius": 0.42}}]}
RIVETS = {"kind": "rivets", "strength": 1.8, "swing": 1.5,
          "params": {"radius": 0.2, "inset": 0.3, "seat": 0.18, "every": 3}}
# The cart's iron is drawn from near black to dark grey. Metal albedo is
# reflectance, so the near black plates are a dark iron dielectric (the
# hopper's lesson); the lighter grey straps and rims, at 0.2 luminance and
# over, are bare worn iron and reflect as metal.
CART_DARK = {"mode": "shade", "base": 0.86, "span": 0.12, "levels": 3, "detail": 0.3,
             "joints": False, "smooth": 0.46, "smooth_spread": 0.03, "micro": "mix",
             "micro_params": {"layers": PLATE_MIX["layers"] + [RIVETS]}, "wear": 0.1,
             "metal": False}
CART_IRON = {"mode": "shade", "base": 0.9, "span": 0.08, "levels": 2, "detail": 0.3,
             "joints": False, "metal": True, "smooth": 0.62, "smooth_spread": 0.03,
             "micro": "mix", "micro_params": PLATE_MIX, "wear": 0.1}
CART_PLANK = dict(PLANK, base=0.78, span=0.12, metal=False)
CART_NARROW = dict(NARROW_PLANK, metal=False)


def minecart_specs():
    stem = "mcl_minecarts_minecart"
    MODELS[stem] = ("mcl_minecarts_minecart.b3d", 0)
    src = lib.load_source(stem, GAME)
    h, w = src.shape[:2]
    narrow = narrow_mask("mcl_minecarts_minecart.b3d", 0, w, h, most=2)
    mat = np.full((h, w), "plank", dtype=object)
    for x, y, hh, s, L in texels(src):
        if s < 0.1:
            mat[y, x] = "iron" if L >= 0.2 else "dark_iron"
        elif narrow[y, x]:
            mat[y, x] = "narrow"
    return {stem: spec_of(mat, {"plank": CART_PLANK, "narrow": CART_NARROW,
                                "dark_iron": CART_DARK, "iron": CART_IRON}, src, "metal")}


FAMILIES = {"boats": boat_specs, "minecart": minecart_specs}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check_only = "--check" in sys.argv
    stale = []
    for name in args or list(FAMILIES):
        for stem, spec in FAMILIES[name]().items():
            if not mf.write(stem, spec, check_only):
                stale.append(stem)
    if "--models" in sys.argv:
        for stem, (model, brush) in sorted(MODELS.items()):
            print(stem, model, brush)
    for s in stale:
        print(("differs " if check_only else "wrote ") + s)
    if check_only and stale:
        sys.exit(1)


if __name__ == "__main__":
    main()
