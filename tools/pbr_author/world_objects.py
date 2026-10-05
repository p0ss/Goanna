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


# --- worn armour --------------------------------------------------------------------------
# mcl_armor_character.b3d brush 1 ("Armor") draws (feet)^(legs)^(torso)^(head),
# each piece a 64 x 32 image on the player's layout, the elytra in the torso
# slot. Zombies, skeletons and the rest wear the same images on their own
# armour brush. Leather is dyed by multiplying a grey copy
# (*_leather_desat^[multiply:<colour>]), so the copy takes the leather's own
# material map. Trims are drawn over a piece as
# ^(<pattern>_<piece>.png^[colorize:<colour>:150): a raised metal inlay,
# built as an overlay standing over the plate.

ARMOUR_KINDS = ("leather", "leather_desat", "chain", "copper", "iron", "gold", "diamond",
                "netherite")
ARMOUR_PIECES = ("helmet", "chestplate", "leggings", "boots")
TRIMS = ("bolt", "coast", "dune", "eye", "flow", "rib", "sentry", "silence", "snout", "spire",
         "tide", "vex", "ward", "wayfinder", "wild")

# Worn polished plate: lighter higher by a shallow step, the darkest
# outline texels sunk a little as the seams between plates.
ARM_PLATE = {"mode": "shade", "base": 0.86, "span": 0.12, "levels": 3, "detail": 0.3,
             "joints": True, "joint": 0.12, "metal": True, "smooth": 0.72, "smooth_spread": 0.03,
             "micro": "metal_worn", "wear": 0.12}
# Diamond: gem plate, F0 0.17 and polished only on the gem.
ARM_GEM = {"mode": "shade", "base": 0.84, "span": 0.12, "levels": 3, "detail": 0.3,
           "joints": False, "smooth": 0.9, "smooth_spread": 0.02, "f0": 0.17, "micro": "glass",
           "micro_strength": 0.4, "wear": 0.06}
# The dark frame a diamond piece is set in: dark iron, a dielectric.
ARM_FRAME = {"mode": "shade", "base": 0.8, "span": 0.1, "levels": 2, "detail": 0.3,
             "joints": False, "metal": False, "smooth": 0.5, "smooth_spread": 0.03,
             "micro": "metal_worn", "wear": 0.1}
# Netherite's dark plate: polished dark metal drawn near black, so a
# dielectric; its lighter edging is the metal.
ARM_DARK = {"mode": "shade", "base": 0.84, "span": 0.12, "levels": 3, "detail": 0.3,
            "joints": False, "metal": False, "smooth": 0.64, "smooth_spread": 0.03,
            "micro": "metal_worn", "wear": 0.12}
# Mail: one height per shade band, the art's lighter texels the rings and
# its darkest the gaps between, a ring of round wire per texel in the
# normal. Rings at 0.2 luminance and over are metal; the gaps a dielectric.
ARM_CHAIN = {"mode": "flat", "base": 0.9, "span": 0.0, "metal": True, "smooth": 0.66,
             "smooth_spread": 0.0, "micro": "chain", "micro_strength": 1.0, "wear": 0.1}
ARM_CHAIN_GAP = dict(ARM_CHAIN, base=0.87, metal=False, smooth=0.4)
# Stitched leather, soft: lighter a little higher, steps rounded, the box
# edges rolled rather than bevelled, stitching inside each piece's edge.
ARM_LEATHER = {"mode": "soft", "base": 0.88, "span": 0.1, "detail": 0.25, "soft_edge": 0.3,
               "round": 3, "edge_roll": 1.5, "edge_lean": 18, "roll_rough": 0.03,
               "metal": False, "smooth": 0.36, "smooth_spread": 0.02, "micro": "leather",
               "micro_strength": 0.5, "wear": 0.15,
               "stitch": {"inset": 0.22, "length": 0.36, "gap": 0.18, "width": 0.07,
                          "groove": 0.05, "depth": 0.03}}
# Straps and belts under and between plates: leather, one height. Most are
# a single texel wide, too thin for a rolled edge or a stitched one: a
# roll there leaned inward at the face borders, and the stitch groove sat
# on the border row.
ARM_STRAP = {"mode": "flat", "base": 0.9, "span": 0.0, "metal": False, "micro": "leather",
             "smooth": 0.38, "smooth_spread": 0.0, "micro_strength": 0.35, "wear": 0.12}
ARM_BUCKLE = {"mode": "flat", "base": 0.94, "span": 0.0, "metal": True, "smooth": 0.7,
              "smooth_spread": 0.0, "micro": "metal_worn", "wear": 0.1}
# Padding and surcoats: one soft cloth whatever its check.
ARM_CLOTH = {"mode": "soft", "base": 0.9, "span": 0.06, "detail": 0.25, "soft_edge": 0.3,
             "round": 3, "edge_roll": 1.5, "edge_lean": 18, "roll_rough": 0.03, "metal": False,
             "smooth": 0.16, "smooth_spread": 0.02, "micro": "canvas", "micro_strength": 0.7,
             "wear": 0.1, "scatter": 0.25}
# Small coloured accents (the gold helmet's violet band, netherite's red
# studs): enamel, flat, a little proud and polished.
ARM_ACCENT = {"mode": "flat", "base": 0.94, "span": 0.0, "metal": False, "smooth": 0.62,
              "smooth_spread": 0.0, "micro": "none"}
# The elytra: wing membrane, soft and satin, on dark ribs.
ELYTRA_MEMBRANE = {"mode": "soft", "base": 0.86, "span": 0.08, "detail": 0.25, "soft_edge": 0.3,
                   "round": 3, "edge_roll": 1.5, "edge_lean": 12, "roll_rough": 0.03,
                   "metal": False, "smooth": 0.48, "smooth_spread": 0.02, "micro": "hide",
                   "micro_params": {"cell": 0.6, "wrinkles": 0.8}, "micro_strength": 0.35,
                   "scatter": 0.35}
ELYTRA_EDGE = {"mode": "flat", "base": 0.96, "span": 0.0, "metal": False, "smooth": 0.48,
               "smooth_spread": 0.0, "micro": "hide", "micro_params": {"cell": 0.6, "wrinkles": 0.8},
               "micro_strength": 0.35, "scatter": 0.35}
ELYTRA_RIB = {"mode": "flat", "base": 0.96, "span": 0.0, "metal": False, "micro": "bone",
              "micro_strength": 0.4, "micro_params": {"cracks": 0.2}, "smooth": 0.42,
              "smooth_spread": 0.0}
# A trim: raised metal inlay over the plate, lighter a little higher; the
# near black texels of a pattern a dielectric.
TRIM_INLAY = {"mode": "shade", "base": 0.94, "span": 0.06, "levels": 2, "detail": 0.3,
              "joints": False, "metal": True, "smooth": 0.74, "smooth_spread": 0.02,
              "micro": "metal_worn", "wear": 0.08}
TRIM_DARK = dict(TRIM_INLAY, metal=False, smooth=0.5)
TRIM_COVER = 0.2


def armour_material(kind, hh, s, L):
    if kind in ("leather", "leather_desat"):
        return "leather"
    if 0.035 <= hh <= 0.07 and 0.4 <= s <= 0.52 and L < 0.36:
        return "strap"
    if kind != "gold" and 0.11 <= hh <= 0.14 and s > 0.5 and L > 0.6:
        return "buckle"
    if kind == "chain":
        if 0.55 <= hh <= 0.66 and s >= 0.05 and L < 0.36:
            return "chain" if L >= 0.2 else "chain_gap"
        if s > 0.6 and (hh > 0.95 or hh < 0.03):
            return "cloth"
        if 0.08 <= hh <= 0.12 and 0.1 <= s <= 0.2 and L > 0.6:
            return "cloth"
        return "plate"
    if kind == "copper":
        return "plate" if L >= 0.21 else "dark"
    if kind == "gold":
        if 0.06 < hh < 0.16 and s > 0.5:
            return "plate"
        if 0.6 < hh < 0.85:
            return "accent"
        return "cloth"
    if kind == "diamond":
        return "gem" if s > 0.3 or L > 0.9 else "frame"
    if kind == "netherite":
        if s > 0.5 and (hh > 0.95 or hh < 0.03):
            return "accent"
        return "plate" if L >= 0.25 else "dark"
    return "plate" if L >= 0.2 else "dark"


ARMOUR_MATERIALS = {"plate": ARM_PLATE, "dark": ARM_DARK, "gem": ARM_GEM, "frame": ARM_FRAME,
                    "chain": ARM_CHAIN, "chain_gap": ARM_CHAIN_GAP, "leather": ARM_LEATHER,
                    "strap": ARM_STRAP, "buckle": ARM_BUCKLE, "cloth": ARM_CLOTH,
                    "accent": ARM_ACCENT}


def armour_specs():
    out = {}
    model = ("mcl_armor_character.b3d", 1)
    for piece in ARMOUR_PIECES:
        leather = None
        for kind in ARMOUR_KINDS:
            stem = "mcl_armor_%s_%s" % (piece, kind)
            MODELS[stem] = model
            src = lib.load_source(stem, GAME)
            h, w = src.shape[:2]
            mat = np.full((h, w), "plate", dtype=object)
            for x, y, hh, s, L in texels(src):
                mat[y, x] = armour_material(kind, hh, s, L)
            mats = dict(ARMOUR_MATERIALS)
            if kind == "netherite":
                # Netherite's own dark plate and its edging, a little less
                # polished than iron's.
                mats["plate"] = dict(ARM_PLATE, smooth=0.66)
            if kind == "leather":
                leather = mat
            if kind == "leather_desat" and leather is not None:
                mat = leather.copy()
            # Soft leather's rounded steps and rolled edges add to the
            # march; a little less strength keeps it under the cap.
            # The box bevel a little deeper than the boats' so it still
            # leans outward where a plate's sunk seam or a belt reaches the
            # face's border; gold's belted leggings need more.
            extra = {"bevel_depth": 0.15 if stem == "mcl_armor_leggings_gold" else 0.12}
            if kind.startswith("leather"):
                extra["strength"] = 21.0
            out[stem] = spec_of(mat, mats, src, "metal", extra)
    stem = "mcl_armor_elytra"
    MODELS[stem] = model
    src = lib.load_source(stem, GAME)
    mat = np.full(src.shape[:2], "membrane", dtype=object)
    # A wing's edges are faces two texels across: one height there.
    narrow = narrow_mask(model[0], model[1], src.shape[1], src.shape[0], most=2)
    for x, y, hh, s, L in texels(src):
        if s < 0.1:
            mat[y, x] = "rib"
        elif narrow[y, x]:
            mat[y, x] = "edge"
    out[stem] = spec_of(mat, {"membrane": ELYTRA_MEMBRANE, "rib": ELYTRA_RIB,
                              "edge": ELYTRA_EDGE}, src, "cloth")
    for trim in TRIMS:
        for piece in ARMOUR_PIECES:
            stem = "%s_%s" % (trim, piece)
            MODELS[stem] = model
            # Some patterns are drawn translucent (wayfinder's texels are
            # all under half alpha, sentry's partly): "cover" counts a
            # texel at a fifth alpha or more as inlay, and the client lays
            # its maps over the plate by that alpha.
            src = lib.load_source(stem, GAME).copy()
            a = src[..., 3]
            if not (a >= TRIM_COVER).any():
                # wayfinder_leggings is an empty image: nothing to inlay.
                del MODELS[stem]
                continue
            src[..., 3] = np.where(a >= TRIM_COVER, 1.0, a)
            mat = np.full(src.shape[:2], "inlay", dtype=object)
            for x, y, hh, s, L in texels(src):
                if L < 0.2:
                    mat[y, x] = "inlay_dark"
            out[stem] = spec_of(mat, {"inlay": TRIM_INLAY, "inlay_dark": TRIM_DARK}, src,
                                "metal", {"overlay": True, "surface": 0.9, "cover": TRIM_COVER})
    return out


FAMILIES = {"boats": boat_specs, "minecart": minecart_specs, "armour": armour_specs}


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
