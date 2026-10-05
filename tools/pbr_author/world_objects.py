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
  minecart   the cart body every minecart draws: a few large worn iron
             plates around a box of planks. What a cart carries is drawn
             with the block's own images and maps.
  armour     the worn layers on players and mobs, every kind and piece,
             the elytra and the trims (see "worn armour" below).
  objects    the bell, the arrow, banners and their patterns, the shield,
             the trident, bows and crossbows and the fishing rod held in
             hand, paintings, campfire logs and the chests the chest
             entity draws (see "held and placed objects" below).

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
# planks of a box in a frame of iron plates.
#
# Until 2026-10-05 every iron texel was a plate as on the iron golem (a
# crisp bevel, a tilt and step per plate, rivets by rule), and on the GPU
# the cart read as a grid of separate bevelled tiles
# (evidence/minecart_tiles_on_2x.png): that suits a golem, but a cart is
# a few large plates. Now neighbouring close shades merge into plates
# (extrude.merge_plateaus, as the hair styles and sculpt_crisp merge),
# crisp steps fall only between those, and the plates keep the golem's
# scratches and dents without the per texel bevel. The art draws no rivet
# heads, so none are added.

# Merge share: a plateau's shades span at most this share of the
# material's shade range.
PLATE_MERGE = 0.5
# The cart's near black iron is drawn as a fine checker of close shades
# (cast iron's mottle), wider apart than half its narrow range: at 0.5 the
# rim still stood as a texel checker, so its plates merge further.
CART_MERGE = 0.75
# The iron golem's wear, which reads well on the GPU: a few fine
# scratches and the odd soft hammer dent inside each texel.
WEAR = {"layers": [
    {"kind": "scratches", "strength": 0.3, "swing": 0.6,
     "params": {"count": 0.35, "length": 0.4, "width": 0.03}},
    {"kind": "dents", "strength": 0.6, "params": {"density": 0.25, "second": 0, "radius": 0.42}}]}
# The cart's iron is drawn from near black to dark grey. Metal albedo is
# reflectance, so the near black plates are a dark iron dielectric (the
# hopper's lesson); the lighter grey straps and rims, at 0.2 luminance and
# over, are bare worn iron and reflect as metal.
CART_DARK = {"mode": "shade", "base": 0.86, "span": 0.12, "levels": 3, "detail": 0.3,
             "joints": False, "merge": CART_MERGE, "smooth": 0.46, "smooth_spread": 0.03,
             "micro": "mix", "micro_params": WEAR, "wear": 0.1, "metal": False}
CART_IRON = {"mode": "shade", "base": 0.9, "span": 0.08, "levels": 2, "detail": 0.3,
             "joints": False, "merge": PLATE_MERGE, "metal": True, "smooth": 0.62,
             "smooth_spread": 0.03, "micro": "mix", "micro_params": WEAR, "wear": 0.1}
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
# A piece of armour is a few large plates, not one per texel: on the GPU
# (2026-10-05) gold, netherite and iron read as a grid of bevelled tiles,
# one per art texel. Neighbouring close shades merge into one plateau
# first, as the cart's (PLATE_MERGE), so the crisp steps fall between the
# art's plates only.
# Iron is worn steel, bright but not a mirror. At 0.72 its near white art
# blew out on the chestplate under an afternoon and a low sun, and by a
# lantern at night, and the helmet read as glassy chrome; 0.62 with a
# wider spread (the darker, lower texels rougher) and the golem's wear.
ARM_IRON = dict(ARM_PLATE, merge=PLATE_MERGE, smooth=0.62, smooth_spread=0.08, micro="mix",
                micro_params=WEAR)
# Gold and copper keep their polish, merged into plates.
ARM_GOLD = dict(ARM_PLATE, merge=PLATE_MERGE)
ARM_COPPER = dict(ARM_PLATE, merge=PLATE_MERGE)
# Diamond: gem plate, F0 0.17 and polished only on the gem. A dielectric:
# without "metal": false the stem's class (metal) set every gem texel's
# metal flag, which overrides the F0 (the _s green byte was 255), and on
# the GPU (2026-10-05) a few chestplate texels drew black with maps on.
ARM_GEM = {"mode": "shade", "base": 0.84, "span": 0.12, "levels": 3, "detail": 0.3,
           "joints": False, "metal": False, "smooth": 0.9, "smooth_spread": 0.02, "f0": 0.17,
           "micro": "glass",
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
# Netherite: its dark plate is drawn near black and its lighter edging a
# warm brown. As metal the edging reflected the warm sky through that
# brown and the piece read as bronze with a hot spot (GPU, 2026-10-05).
# Both are dielectric: a dark satin plate at moderate smoothness, the
# edging a little rougher, merged into plates as the other armour.
NETH_DARK = dict(ARM_DARK, merge=PLATE_MERGE, smooth=0.52, smooth_spread=0.04)
NETH_EDGE = dict(ARM_PLATE, merge=PLATE_MERGE, metal=False, smooth=0.46, smooth_spread=0.04)
# Mail: the art draws it as a checker, a lighter texel (a ring, 0.2
# luminance and over) beside a darker one (the gap). Each ring texel is
# one ring of round wire a texel across, centred in it (the chain kind's
# "grid"), metal and smoother on the wire's top; each gap texel dark,
# rough, flat and a dielectric. Rings laid over both shades regardless of
# the checker read on the GPU as dark speckled granite with a bronze cast.
ARM_CHAIN = {"mode": "flat", "base": 0.9, "span": 0.0, "metal": True, "smooth": 0.7,
             "smooth_spread": 0.0, "micro": "chain", "micro_strength": 1.0,
             "micro_params": {"grid": True, "radius": 0.31, "wire": 0.14, "lean": 0.25},
             "wear": 0.06}
ARM_CHAIN_GAP = {"mode": "flat", "base": 0.86, "span": 0.0, "metal": False, "smooth": 0.28,
                 "smooth_spread": 0.0, "micro": "none"}
# Stitched leather, soft: lighter a little higher, steps rounded, the box
# edges rolled rather than bevelled, stitching inside each piece's edge.
# On the GPU (2026-10-05) the dyed leather read as felt: the leather
# kind's fine pores and creases were fuzz at a viewing distance. Now a
# pebbled grain (cells about a third of a texel, smoother on their tops,
# no pores), a soft sheen at 0.42, and the stitches wider and deeper so
# they show.
ARM_LEATHER = {"mode": "soft", "base": 0.88, "span": 0.1, "detail": 0.25, "soft_edge": 0.3,
               "round": 3, "edge_roll": 1.5, "edge_lean": 18, "roll_rough": 0.03,
               "metal": False, "smooth": 0.42, "smooth_spread": 0.03, "micro": "leather",
               "micro_strength": 0.8,
               "micro_params": {"cell": 0.32, "pores": 0.0, "crease": 0.5, "sheen": 0.9},
               "wear": 0.1,
               "stitch": {"inset": 0.24, "length": 0.4, "gap": 0.2, "width": 0.09,
                          "groove": 0.06, "depth": 0.07}}
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
                mats["plate"] = NETH_EDGE
                mats["dark"] = NETH_DARK
            elif kind in ("iron", "chain"):
                mats["plate"] = ARM_IRON
            elif kind == "gold":
                mats["plate"] = ARM_GOLD
            elif kind == "copper":
                mats["plate"] = ARM_COPPER
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


# --- held and placed objects --------------------------------------------------------------
# Model atlases (atlas.py): the bell's body (mcl_bells_bell.b3d), the arrow in
# flight (mcl_bows_arrow.b3d, and the tipped arrow's ^ overlay), the banner's
# cloth and pole (amc_banner.b3d; the wall banner draws the same image) and
# its pattern overlays. Tiles and flat images (extrude.py, as the hand
# tools): the chests' double and present images (the entity draws them as
# the single chests' are drawn), the shield's face (mcl_shield.obj), the
# trident (mcl_tridents_trident.obj), the bows, crossbows, arrow and fishing
# rod held in hand (their inventory image extruded as a wield mesh), the
# paintings' frame and canvases (a cube), the campfire's logs and the item
# frames held in hand.

# The bell: worked gold, lighter higher by a shallow step, polished; the
# dark of its mouth a dielectric; its iron yoke worn iron. At 0.74 the
# bell read pale and washed out on the GPU (2026-10-05): every shade
# mirrored the same bright sky. A little less polish, and a wider spread
# so the art's darker shades are rougher and keep their contrast.
BELL_GOLD = {"mode": "shade", "base": 0.86, "span": 0.12, "levels": 3, "detail": 0.3,
             "joints": False, "metal": True, "smooth": 0.64, "smooth_spread": 0.12,
             "micro": "metal_worn", "wear": 0.1}
BELL_MOUTH = {"mode": "flat", "base": 0.8, "span": 0.0, "metal": False, "smooth": 0.4,
              "smooth_spread": 0.0, "micro": "none"}
BELL_IRON = {"mode": "shade", "base": 0.88, "span": 0.08, "levels": 2, "detail": 0.3,
             "joints": False, "metal": True, "smooth": 0.55, "smooth_spread": 0.03,
             "micro": "metal_worn", "wear": 0.12}
# The arrow: a shaft of wood, fletching, an iron head.
ARROW_SHAFT = dict(NARROW_PLANK, base=0.94)
ARROW_FLETCH = {"mode": "flat", "base": 0.96, "span": 0.0, "metal": False, "smooth": 0.3,
                "smooth_spread": 0.0, "micro": "feather", "micro_strength": 0.5,
                "micro_params": {"length": 0.8, "width": 0.6}}
ARROW_HEAD = {"mode": "flat", "base": 0.98, "span": 0.0, "metal": True, "smooth": 0.62,
              "smooth_spread": 0.0, "micro": "metal_worn", "wear": 0.1}
# The banner: linen cloth, soft, its folds the art's shading; the pole wood
# with rope bindings.
BANNER_CLOTH = {"mode": "soft", "base": 0.9, "span": 0.1, "detail": 0.25, "soft_edge": 0.3,
                "round": 3, "edge_roll": 1.5, "edge_lean": 18, "roll_rough": 0.03,
                "metal": False, "smooth": 0.14, "smooth_spread": 0.02, "micro": "linen",
                "micro_strength": 0.8, "wear": 0.08, "scatter": 0.3}
BANNER_POLE = dict(NARROW_PLANK, base=0.94)
BANNER_STRENGTH = 14.0

# Held in hand, as the hand tools (default_tool_*): wood by shade, the
# string flat, iron by shade and polished.
HELD_WOOD = {"mode": "shade", "base": 0.5, "span": 0.35}
HELD_STRING = {"mode": "flat", "base": 0.7, "span": 0.0, "smooth": 0.3, "micro": 0.04}
HELD_METAL = {"mode": "shade", "base": 0.6, "span": 0.35, "metal": True, "smooth": 0.78}
HELD_FEATHER = {"mode": "shade", "base": 0.6, "span": 0.2, "smooth": 0.3, "joints": False}
HELD_PAINT = {"mode": "flat", "base": 0.75, "span": 0.0, "smooth": 0.6, "micro": 0.02}

# The shield's face: planks by shade with sunk seams, a dark iron rim and
# boss, a dielectric (drawn near black).
SHIELD_WOOD = {"mode": "shade", "base": 0.55, "span": 0.3, "levels": 3, "joint": 0.3}
SHIELD_IRON = {"mode": "shade", "base": 0.75, "span": 0.15, "levels": 2, "joints": False,
               "metal": False, "smooth": 0.45}
# The trident: polished pale metal prongs, a sea-green gem, a shaft.
TRIDENT_METAL = {"mode": "shade", "base": 0.65, "span": 0.3, "metal": True, "smooth": 0.8,
                 "joints": False}
TRIDENT_GEM = {"mode": "flat", "base": 0.85, "span": 0.0, "smooth": 0.9, "f0": 0.17,
               "emission": 0.2}
# The campfire's logs: bark by shade (fissures sunk), the cut ends'
# rings, and on the lit logs the embers glowing by shade.
LOG_BARK = {"mode": "shade", "base": 0.4, "span": 0.5, "levels": 3}
LOG_CUT = {"mode": "shade", "base": 0.55, "span": 0.3, "levels": 2, "joints": False}
LOG_EMBER = {"mode": "shade", "base": 0.35, "span": 0.3, "levels": 2, "joints": False,
             "smooth": 0.3, "emission": 0.9, "emission_shade": True}
# A painting's frame: wood by shade. Its canvas: flat, matte, a faint weave
# from the stem's cloth micro surface and no per texel step, so the picture
# stays a picture.
FRAME_WOOD = {"mode": "shade", "base": 0.45, "span": 0.4, "levels": 3}
CANVAS = {"mode": "flat", "base": 0.5, "span": 0.0, "micro": 0.0, "smooth": 0.12}
# A present: wrapping paper, nearly flat and a little glossy; the ribbon
# proud of it; the dark inside of the lid low.
PRESENT_PAPER = {"mode": "shade", "base": 0.55, "span": 0.12, "levels": 2, "joints": False,
                 "smooth": 0.5}
PRESENT_RIBBON = {"mode": "shade", "base": 0.8, "span": 0.12, "levels": 2, "joints": False,
                  "smooth": 0.62}
PRESENT_INSIDE = {"mode": "flat", "base": 0.2, "span": 0.0, "smooth": 0.2, "micro": 0.0}

PAINTINGS = ("ancient_octopus", "balding_man", "battle_axe", "blue_banner", "butcher_knives",
             "cooking_utensils", "decorative_swords", "dense_jungle_forest", "desert_castle",
             "elf_utopia", "endless_dunes", "froggy_pond", "gloom_mountain", "green_banner",
             "green_bottles", "moonshine_tundra", "mountain_tower", "notes", "poster",
             "quest_board", "sarmatian_decoration", "snowy_mountain", "support_truss",
             "viking_shield", "volendam_costume", "waterfall_bridge")
BANNER_NOT_PATTERNS = ("banner_base", "base", "base_inverted", "fallback_wood")


def hexes(src):
    q = np.clip(np.round(src[..., :3] * 255.0), 0, 255).astype(int)
    return ["#%02x%02x%02x" % tuple(c) for c in q.reshape(-1, 3)]


def tile_spec(stem, rule, materials, cls, extra=None):
    """A palette spec for extrude.py: rule(h, s, L) names each drawn
    colour's material; the first material is the default."""
    src = lib.load_source(stem, GAME)
    first = list(materials)[0]
    pal = {}
    for x, y, hh, s, L in texels(src):
        q = tuple(int(v) for v in np.clip(np.round(src[y, x, :3] * 255.0), 0, 255))
        m = rule(hh, s, L)
        if m != first:
            pal["#%02x%02x%02x" % q] = m
    used = {first} | set(pal.values())
    spec = {"class": cls}
    spec.update(extra or {})
    spec["materials"] = {k: v for k, v in materials.items() if k in used}
    if pal:
        spec["palette"] = dict(sorted(pal.items()))
    return spec


def held_rule(hh, s, L):
    if s > 0.6 and (hh > 0.9 or hh < 0.03):
        return "paint"
    if hh < 0.04 and 0.08 <= s <= 0.25 and L > 0.55:
        return "feather"
    if s < 0.13 and L > 0.3:
        return "metal"
    if s < 0.22 and L > 0.55:
        return "string"
    return "wood"


def object_specs():
    out = {}
    # The bell's body.
    stem = "mcl_bells_bell_uv_bell"
    MODELS[stem] = ("mcl_bells_bell.b3d", 0)
    src = lib.load_source(stem, GAME)
    mat = np.full(src.shape[:2], "gold", dtype=object)
    for x, y, hh, s, L in texels(src):
        if s < 0.35:
            mat[y, x] = "iron"
        elif L < 0.25:
            mat[y, x] = "mouth"
    out[stem] = spec_of(mat, {"gold": BELL_GOLD, "mouth": BELL_MOUTH, "iron": BELL_IRON}, src,
                        "metal")
    # The arrow in flight, and the tipped arrow's tint over its head.
    for stem in ("mcl_bows_arrow", "mcl_bows_arrow_overlay"):
        MODELS[stem] = ("mcl_bows_arrow.b3d", 0)
        src = lib.load_source(stem, GAME)
        mat = np.full(src.shape[:2], "shaft", dtype=object)
        for x, y, hh, s, L in texels(src):
            if hh < 0.04 and 0.08 <= s <= 0.25:
                mat[y, x] = "fletch"
            elif s < 0.13 and L > 0.3:
                mat[y, x] = "head"
        # The arrow is crossed flat cards, not boxes: no box edge to bevel.
        extra = {"face_edge": "flat"}
        if stem.endswith("overlay"):
            extra.update({"overlay": True, "surface": 0.94})
        out[stem] = spec_of(mat, {"shaft": ARROW_SHAFT, "fletch": ARROW_FLETCH,
                                  "head": ARROW_HEAD}, src, "wood", extra)
    # The banner's cloth and pole, and each pattern laid over the cloth at
    # the cloth's own height texel for texel, so a pattern changes the
    # colour and not the folds.
    stem = "mcl_banners_banner_base"
    MODELS[stem] = ("amc_banner.b3d", 0)
    src = lib.load_source(stem, GAME)
    mat = np.full(src.shape[:2], "cloth", dtype=object)
    for x, y, hh, s, L in texels(src):
        if L < 0.45:
            mat[y, x] = "pole"
        elif s > 0.1 and L < 0.85:
            mat[y, x] = "lashing"
    # The banner is drawn two and a half times a mob's size, so its texels
    # are larger and the same rise per texel is a deeper march: a lower
    # strength keeps it under the client's cap.
    base = spec_of(mat, {"cloth": BANNER_CLOTH, "pole": BANNER_POLE, "lashing": LASHING}, src,
                   "cloth", {"strength": BANNER_STRENGTH})
    out[stem] = base
    import extrude
    bh = extrude.heights(src, base, "cloth")[0]
    cloth = mat == "cloth"
    pats = sorted(p.stem[len("mcl_banners_"):] for p in
                  lib.GAMES[GAME]["art"].rglob("mcl_banners_*.png"))
    for name in pats:
        if name in BANNER_NOT_PATTERNS or name.startswith(("item_", "pattern_")):
            continue
        stem = "mcl_banners_" + name
        MODELS[stem] = ("amc_banner.b3d", 0)
        psrc = lib.load_source(stem, GAME)
        rb = np.round(bh.astype(np.float64), 3)
        levels = sorted(set(rb[cloth].tolist()))
        chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        assert len(levels) <= len(chars), len(levels)
        legend = {chars[i]: {"material": "cloth", "h": lv} for i, lv in enumerate(levels)}
        sym = {lv: chars[i] for i, lv in enumerate(levels)}
        drawn = psrc[..., 3] >= 0.5
        grid = ["".join(sym[float(rb[y, x])] if drawn[y, x] and cloth[y, x] else "."
                        for x in range(psrc.shape[1])) for y in range(psrc.shape[0])]
        spec = dict(HEAD)
        spec.update({"class": "cloth", "strength": BANNER_STRENGTH, "overlay": True, "surface": 0.9,
                     "materials": {"cloth": dict(BANNER_CLOTH, mode="flat", span=0.0)},
                     "grid": grid, "legend": legend})
        out[stem] = spec
    # Tiles and flat images.
    held = {"wood": HELD_WOOD, "metal": HELD_METAL, "string": HELD_STRING,
            "feather": HELD_FEATHER, "paint": HELD_PAINT}
    for stem in ("mcl_bows_bow", "mcl_bows_bow_0", "mcl_bows_bow_1", "mcl_bows_bow_2",
                 "mcl_bows_crossbow", "mcl_bows_crossbow_0", "mcl_bows_crossbow_1",
                 "mcl_bows_crossbow_2", "mcl_bows_crossbow_3", "mcl_bows_arrow_inv",
                 "mcl_fishing_fishing_rod"):
        out[stem] = tile_spec(stem, held_rule, held, "wood")
    for stem in ("mcl_itemframes_item_frame", "mcl_itemframes_glow_item_frame"):
        out[stem] = tile_spec(stem, lambda hh, s, L: "wood", {"wood": HELD_WOOD}, "wood")
    out["mcl_shield_base_nopattern"] = tile_spec(
        "mcl_shield_base_nopattern", lambda hh, s, L: "iron" if s < 0.1 else "wood",
        {"wood": SHIELD_WOOD, "iron": SHIELD_IRON}, "wood")
    for stem in ("mcl_tridents_trident_entity", "mcl_tridents_trident_entity_clip"):
        out[stem] = tile_spec(
            stem, lambda hh, s, L: ("gem" if s > 0.8 else "metal" if s < 0.2 else "wood"),
            {"metal": TRIDENT_METAL, "wood": HELD_WOOD, "gem": TRIDENT_GEM}, "metal")
    for stem in ("mcl_campfires_log", "mcl_campfires_campfire_log_lit",
                 "mcl_campfires_soul_campfire_log_lit"):
        out[stem] = tile_spec(
            stem, lambda hh, s, L: ("ember" if s > 0.45 and not (0.05 <= hh <= 0.09 and L > 0.3)
                                    and not (0.05 <= hh <= 0.09 and s < 0.5)
                                    else "cut" if 0.04 <= hh <= 0.1 and s > 0.25 else "bark"),
            {"bark": LOG_BARK, "cut": LOG_CUT, "ember": LOG_EMBER}, "wood")
    out["mcl_paintings_frame"] = tile_spec("mcl_paintings_frame", lambda hh, s, L: "wood",
                                           {"wood": FRAME_WOOD}, "wood")
    for name in PAINTINGS:
        stem = "mcl_paintings_painting_" + name
        out[stem] = tile_spec(stem, lambda hh, s, L: "canvas", {"canvas": CANVAS}, "cloth",
                              {"micro": "cloth", "micro_strength": 0.5})
    # The chests the entity draws: doubles as the single chests are built
    # (no spec, class wood), presents as paper and ribbon.
    for stem in ("mcl_chests_normal_double", "mcl_chests_trapped_double"):
        out[stem] = {"class": "wood"}
    for stem in ("mcl_chests_normal_present", "mcl_chests_trapped_present",
                 "mcl_chests_ender_present", "mcl_chests_normal_double_present",
                 "mcl_chests_trapped_double_present"):
        src = lib.load_source(stem, GAME)
        hues = [hh for x, y, hh, s, L in texels(src) if s > 0.3 and L > 0.12]
        paper = float(np.median(hues)) if hues else 0.0

        def rule(hh, s, L, paper=paper):
            if L < 0.12:
                return "inside"
            dh = min(abs(hh - paper), 1.0 - abs(hh - paper))
            return "ribbon" if dh > 0.06 or (s < 0.15 and L > 0.6) else "paper"
        out[stem] = tile_spec(stem, rule, {"paper": PRESENT_PAPER, "ribbon": PRESENT_RIBBON,
                                           "inside": PRESENT_INSIDE}, "cloth")
    return out


FAMILIES = {"boats": boat_specs, "minecart": minecart_specs, "armour": armour_specs,
            "objects": object_specs}


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
