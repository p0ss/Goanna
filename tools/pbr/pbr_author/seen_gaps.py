"""Specs for textures drawn in the world that the first census missed.

The Mineclonia audit of 2026-10-05 (stems/mineclonia.audit-2026-10-05.md,
"Seen in the world, not authored") found textures that reach the screen
only through a texture expression, and so could take no maps until the
client composed companions for `^` overlays on node faces, `[combine`,
`[transform` and `[mask` (docs/materials.md, "Companions of texture
expressions"), and a few mesh entities. This writes a spec per stem for
them, in the house style (crisp plateaus on the texel grid, each part its
own material, metal bright, glows from the art's bright texels):

  overlays   drawn only after a ^ on a node face: the nylium sides over
             netherrack, the comparator's front torch in compare and
             subtract mode on its top, sides and ends, and the redstone
             cross's second line. Tiles (extrude.py). Where an overlay is
             drawn its maps replace the base image's, so the parts it
             shares with the base (the slab rows of a comparator's side,
             the netherrack under the warped nylium's fringe) take the
             base's own materials, and its own parts stand where the base
             puts the same thing (an unlit torch where the "off" top has
             one, a lit one where the "on" top has one).
  books      the six books the chiseled bookshelf lays into its front with
             [combine (mcl_books_book_0 to _5, 4 x 6 each). Model atlases
             (atlas.py) with one face each, at 16 map pixels per texel, the
             empty shelf's density: extrude.py would make a 4 texel wide
             part 64 per texel, and the client composes a [combine at the
             finest scale of its parts, so every front would become a 1024
             pixel map. Maps only, like the empty shelf.
  held       the items held through [transform: the carrot and warped
             fungus on a stick (FY then R90) and the screwdriver (FX).
             Tiles; the client turns the companions with the art. Authored
             unrotated, as the inventory image draws them, on the fishing
             rod's materials.
  entities   the wind charge (wind_charge.obj), the worn carved pumpkin and
             jack o'lantern (pumpkin_head.obj, the head armour entity of
             mcl_heads.register_entity), the evoker's fangs, the llama's
             spit and the plain villager skin (mobs_mc_villager.png on
             mobs_mc_villager.b3d, on the villager base's rules and face).
  dragon     the dragon head (mcl_heads_dragon, 108 x 32, on
             mcl_heads_dragon_floor.obj; the wall and ceiling models use
             the same UVs), on the ender dragon's materials.

The armour stand needs nothing: 3d_armor_stand.obj draws default_wood on
its first buffer and mcl_stairs_stone_slab_top on its second, as node
tiles, so it takes those blocks' maps.

    python3 tools/pbr/pbr_author/seen_gaps.py            # write every spec
    python3 tools/pbr/pbr_author/seen_gaps.py --check    # exit 1 if any differs
    python3 tools/pbr/pbr_author/seen_gaps.py books      # one family

MODELS says which model and brush each atlas stem is drawn with, for
atlas.py's --model and --brush until the stem is in the list.
"""
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import mob_families as mf  # noqa: E402
import nether_end_mobs as nem  # noqa: E402

GAME = "mineclonia"

# Atlas stems: (model, brush). The books have no model: their one face is
# the whole image, given in the spec, so the model is never read.
MODELS = {
    "mcl_charges_wind_charge_entity": ("wind_charge.obj", 0),
    "mcl_farming_pumpkin_face": ("pumpkin_head.obj", 0),
    "mcl_farming_pumpkin_face_light": ("pumpkin_head.obj", 0),
    "mobs_mc_evoker_fangs": ("mobs_mc_evoker_fangs.b3d", 0),
    "mobs_mc_llama_spit": ("mobs_mc_llama_spit.b3d", -1),
    "mobs_mc_villager": ("mobs_mc_villager.b3d", 0),
    "mcl_heads_dragon": ("mcl_heads_dragon_floor.obj", 0),
}
BOOKS = ["mcl_books_book_%d" % i for i in range(6)]

# Every atlas stem's keys: end_objects.py's, the box edge bevelled.
HEAD = {"texel_px": 16, "strength": 24.0, "chamfer": 2, "face_edge": "bevel", "bevel_px": 3,
        "bevel_depth": 0.07, "micro": "none"}


def spec_of(mat, materials, src, cls, extra=None):
    """A full grid atlas spec: the first material is the grid's '.'."""
    out = dict(HEAD)
    out["class"] = cls
    out.update(extra or {})
    spec = mf.to_spec(mat, materials, None, src)
    out.update({k: v for k, v in spec.items() if k in ("materials", "grid", "legend")})
    return out


def hexes(src):
    """The hex colour of every texel, as an object array."""
    q = np.clip(np.round(src[..., :3] * 255.0), 0, 255).astype(int)
    out = np.empty(src.shape[:2], dtype=object)
    for y in range(src.shape[0]):
        for x in range(src.shape[1]):
            out[y, x] = "#%02x%02x%02x" % tuple(q[y, x])
    return out


def palette(groups):
    """{hex: material} from {material: [hex, ...]}."""
    return {c: m for m, cs in groups.items() for c in cs}


# --- overlays on node faces ---------------------------------------------------------

# Netherrack has no spec: one shade material of class stone at the
# extrusion's defaults. The warped nylium's side draws its own netherrack
# under the fringe, so that part takes the same.
RACK = {"mode": "shade", "base": 0.35, "span": 0.65}
# The nylium: a fungal mat lying over the rock, so it stands over it,
# lighter a step higher, no joints (its darkest texels are the mat's
# shading, not cracks), matte.
NYLIUM = {"mode": "shade", "base": 0.62, "span": 0.36, "levels": 3, "detail": 0.3,
          "joints": False, "smooth": 0.3}
NETHERRACK = ["#542b21", "#662d28", "#772b28", "#7a2c29", "#902d1e", "#a34332", "#ad5941"]

# The comparator's materials, as its "off" and "on" faces have them: the
# stone slab shaded, the unlit torch sunk dark, the lit torch proud and
# glowing, the torch's stick wood.
C_STONE = {"mode": "shade", "base": 0.35, "span": 0.5}
C_UNLIT_TOP = {"mode": "flat", "base": 0.3, "span": 0, "smooth": 0.3}
C_LIT_TOP = {"mode": "flat", "base": 0.85, "span": 0, "smooth": 0.3, "emission": 0.8,
             "emission_shade": False}
C_WOOD = {"mode": "shade", "base": 0.2, "span": 0.3, "smooth": 0.2}
C_LIT_SIDE = {"mode": "shade", "base": 0.55, "span": 0.25, "joints": False, "emission": 0.8,
              "emission_shade": False}
C_WOODS = ["#514035", "#78604a", "#5d493c", "#675244"]
C_UNLIT = ["#260c0c", "#381212", "#4c1c1c"]
C_LIT = ["#661616", "#721919", "#8e2525"]


def overlay_specs():
    out = {}
    out["crimson_nylium_side"] = {
        "class": "stone",
        "materials": {"nylium": NYLIUM},
    }
    out["warped_nylium_side"] = {
        "class": "stone",
        "materials": {"nylium": NYLIUM, "rack": RACK},
        "palette": palette({"rack": NETHERRACK}),
    }
    # The top's front torch, four texels, drawn over mcl_comparators_off or
    # _on: unlit in compare mode, as the "off" top draws its torches, lit
    # in subtract mode, as the "on" top does.
    out["mcl_comparators_comp"] = {"class": "stone", "materials": {"indicator": C_UNLIT_TOP}}
    out["mcl_comparators_sub"] = {"class": "stone", "materials": {"indicator": C_LIT_TOP}}
    # The sides and ends in subtract mode: the slab's two rows exactly as
    # the base draws them (the same colours, so the same heights) and the
    # lit front torch on its stick, as mcl_comparators_sides_on has it.
    for stem in ("mcl_comparators_sides_sub", "mcl_comparators_ends_sub"):
        out[stem] = {
            "class": "stone",
            "materials": {"stone": C_STONE, "wood": C_WOOD, "glow": C_LIT_SIDE},
            "palette": palette({"wood": C_WOODS, "glow": C_LIT}),
        }
    # The cross's second line is the first line's art; it takes its rule.
    out["redstone_redstone_dust_line1"] = {"class": "stone", "chamfer": 3}
    return out


# --- the chiseled bookshelf's books ---------------------------------------------------

# A leather spine: lighter a shallow step higher (the art's lighter rows
# are the raised bands), its edges rolled by the face bevel, leather grain
# in the normal. It stands a little behind the shelf's frame (0.95) and
# far in front of its dark interior (0.05).
SPINE = {"mode": "shade", "base": 0.74, "span": 0.12, "levels": 2, "detail": 0.3,
         "joints": False, "smooth": 0.38, "smooth_spread": 0.03, "micro": "leather",
         "micro_strength": 0.5, "wear": 0.1}


def book_specs():
    out = {}
    for stem in BOOKS:
        src = lib.load_source(stem, GAME)
        h, w = src.shape[:2]
        mat = np.full((h, w), "spine", dtype=object)
        # The empty shelf is wood at strength 16 and chamfer 1; the books
        # match it, so their rise per texel is the shelf's.
        out[stem] = spec_of(mat, {"spine": SPINE}, src, "wood",
                            {"strength": 16.0, "chamfer": 1, "faces": [[0, 0, w, h]]})
    return out


# --- items held through [transform ------------------------------------------------------

# The fishing rod's materials (specs/mineclonia/mcl_fishing_fishing_rod.json).
ROD_WOOD = {"mode": "shade", "base": 0.5, "span": 0.35, "micro": "wood", "micro_dir": "along"}
ROD_METAL = {"mode": "shade", "base": 0.6, "span": 0.35, "metal": True, "smooth": 0.78,
             "micro": "metal_worn"}
ROD_STRING = {"mode": "flat", "base": 0.7, "span": 0.0, "smooth": 0.3, "step": 0.04,
              "micro": "none"}
METAL = ["#6b635e", "#847e77", "#938e88", "#afaca5", "#c9c7c1", "#e5e4e0"]
STRING = ["#b7a892", "#c8bfaa", "#d6ceb9"]
# The carrot, as farming_carrot has it: the root a little waxy, the leaves
# a step higher and matte.
FOOD = {"mode": "flat", "base": 0.8, "span": 0.0, "smooth": 0.5}
LEAF = {"mode": "flat", "base": 0.88, "span": 0.0, "smooth": 0.35}
CARROT = ["#973b2d", "#a94d39", "#b05d3a", "#b56c40", "#d1925a", "#dda769"]
CARROT_LEAF = ["#2f4c23", "#305a2c", "#4b703d", "#617537"]
# The warped fungus: its teal cap, its dark stalk and the orange flecks.
FUNGUS = {"mode": "flat", "base": 0.84, "span": 0.0, "smooth": 0.35}
STALK = {"mode": "flat", "base": 0.78, "span": 0.0, "smooth": 0.25}
FLECK = {"mode": "flat", "base": 0.88, "span": 0.0, "smooth": 0.4}
CAP = ["#00584b", "#006255", "#007062", "#008172", "#009180"]
DARK = ["#1e1b1e", "#242124", "#2a272a", "#30282f", "#382f39"]
ORANGE = ["#e87b55", "#f28762"]


def held_specs():
    out = {}
    out["mcl_mobitems_carrot_on_a_stick"] = {
        "class": "wood",
        "materials": {"wood": ROD_WOOD, "metal": ROD_METAL, "string": ROD_STRING,
                      "food": FOOD, "leaf": LEAF},
        "palette": palette({"metal": METAL, "string": STRING, "food": CARROT,
                            "leaf": CARROT_LEAF}),
    }
    out["mcl_mobitems_warped_fungus_on_a_stick"] = {
        "class": "wood",
        "materials": {"wood": ROD_WOOD, "metal": ROD_METAL, "string": ROD_STRING,
                      "fungus": FUNGUS, "stalk": STALK, "fleck": FLECK},
        "palette": palette({"metal": METAL, "string": STRING, "fungus": CAP, "stalk": DARK,
                            "fleck": ORANGE}),
    }
    # A wooden handle and a bright steel shaft.
    out["screwdriver"] = {
        "class": "wood",
        "materials": {"wood": ROD_WOOD, "metal": ROD_METAL},
        "palette": palette({"metal": METAL}),
    }
    return out


# --- mesh entities ------------------------------------------------------------------------

# The wind charge: a ball of swirling air, near white, its swirl drawn in
# the alpha. Air has no relief: its faces are four texels across, five
# cubes nest inside one another, and with the dense strands even 0.04 of
# the range over the thin ones (strength 12) the march kept half the area
# of only 57% of one face's texels at 35 degrees. So the strands are one
# height and differ in smoothness only, the box edges bevelled. Its faint
# texels (alpha under a half) are holes the client cuts; built as an
# overlay, as end_objects.py builds the crystal's glass, they stand at the
# strands' height, so the strands do not chamfer down into them.
WIND_DENSE = {"mode": "flat", "base": 0.97, "span": 0.0, "micro": "none", "smooth": 0.62,
              "smooth_spread": 0.0}
WIND_THIN = {"mode": "flat", "base": 0.97, "span": 0.0, "micro": "none", "smooth": 0.5,
             "smooth_spread": 0.0}

# The carved pumpkin worn on the head: the rind's ribs lighter a step
# higher, waxy; the stem wood, proud; the carved holes sunk and rough; in
# the jack o'lantern the holes are lit from inside, sunk less and glowing.
RIND = {"mode": "shade", "base": 0.84, "span": 0.12, "levels": 3, "detail": 0.3,
        "joints": False, "smooth": 0.45, "smooth_spread": 0.03, "micro": "none", "wear": 0.06}
STEM = {"mode": "flat", "base": 0.98, "span": 0.0, "micro": "wood", "micro_dir": "along",
        "micro_strength": 0.8, "smooth": 0.3, "smooth_spread": 0.0}
CARVED = {"mode": "flat", "base": 0.5, "span": 0.0, "micro": "none", "smooth": 0.2,
          "smooth_spread": 0.0}
LIT = {"mode": "flat", "base": 0.6, "span": 0.0, "micro": "none", "smooth": 0.3,
       "smooth_spread": 0.0, "emission": 0.8}
PUMPKIN_STEM = ["#443222", "#5b442c", "#7a5b3b"]
HOLES = ["#591f12", "#722d1c"]

# The evoker's fangs: spectral teeth, enamel smooth, lighter a step higher.
FANG = {"mode": "shade", "base": 0.84, "span": 0.12, "levels": 3, "detail": 0.3,
        "joints": False, "smooth": 0.55, "smooth_spread": 0.03, "micro": "bone",
        "micro_strength": 0.5}

# The llama's spit: one colour, wet, a droplet's smoothness. A small per
# texel step keeps it from being one flat height on its tiny box.
SPIT = {"mode": "flat", "base": 0.96, "span": 0.0, "micro": "none", "step": 0.04,
        "smooth": 0.85, "smooth_spread": 0.0, "f0": 0.02}


def entity_specs():
    out = {}
    stem = "mcl_charges_wind_charge_entity"
    src = lib.load_source(stem, GAME)
    mat = np.where(src[..., 3] >= 0.85, "dense", "thin").astype(object)
    out[stem] = spec_of(mat, {"thin": WIND_THIN, "dense": WIND_DENSE}, src, "glass",
                        {"overlay": True, "surface": 0.97})

    face = lib.load_source("mcl_farming_pumpkin_face", GAME)
    holes = np.isin(hexes(face), HOLES)
    for stem, hole in (("mcl_farming_pumpkin_face", CARVED),
                       ("mcl_farming_pumpkin_face_light", LIT)):
        src = lib.load_source(stem, GAME)
        hx = hexes(src)
        mat = np.full(src.shape[:2], "rind", dtype=object)
        mat[np.isin(hx, PUMPKIN_STEM)] = "stem"
        # The jack o'lantern draws its holes in the rind's own bright
        # oranges, so they are found where the carved face has them.
        mat[holes] = "hole"
        out[stem] = spec_of(mat, {"rind": RIND, "stem": STEM, "hole": hole}, src, "wood")

    stem = "mobs_mc_evoker_fangs"
    src = lib.load_source(stem, GAME)
    out[stem] = spec_of(np.full(src.shape[:2], "fang", dtype=object), {"fang": FANG}, src,
                        "stone")

    stem = "mobs_mc_llama_spit"
    src = lib.load_source(stem, GAME)
    out[stem] = spec_of(np.full(src.shape[:2], "spit", dtype=object), {"spit": SPIT}, src,
                        "glass")
    out.update(villager_spec())
    return out


# The plain villager skin draws the villager base's body and face with a
# robe of a few more greens. It takes the base's spec whole (its face rules,
# the soft skin, the robe's coarse cloth), less the stack, since it is drawn
# alone, and less the variants, which are the base's own studies.
VILLAGER_ROBE = ["#3e4620", "#3f4620", "#3f4921", "#404620", "#465125", "#485226"]


def villager_spec():
    base = json.loads((mf.SPECS / "mobs_mc_villager_base.json").read_text())
    spec = {k: v for k, v in base.items() if k not in ("stack", "variants")}
    pal = dict(spec["palette"])
    pal.update({c: "robe" for c in VILLAGER_ROBE})
    spec["palette"] = pal
    src = lib.load_source("mobs_mc_villager", GAME)
    known = set(pal) | {"#47704c"}
    drawn = hexes(src)[src[..., 3] >= 0.5]
    # Every colour the plain skin draws is the base's or one of the robe's
    # greens; a new colour would fall to skin without anyone deciding it.
    stray = sorted(set(drawn) - known - set(hexes(lib.load_source("mobs_mc_villager_base",
                                                                  GAME)).ravel()))
    if stray:
        raise SystemExit("mobs_mc_villager draws colours the base does not: %s" % stray)
    return {"mobs_mc_villager": spec}


# --- the dragon head ------------------------------------------------------------------------

# The ender dragon's materials (nether_end_mobs.py): black scales, the
# purple grey plates and the magenta on the snout as plate, the eyes (the
# magenta clusters in rows 19 to 22 with their pale centres) glowing.
EYE_ROWS = (19, 23)


def dragon_specs():
    stem = "mcl_heads_dragon"
    src = lib.load_source(stem, GAME)
    h, w = src.shape[:2]
    mat = np.full((h, w), "scale", dtype=object)
    for y in range(h):
        for x in range(w):
            if src[y, x, 3] < 0.5:
                continue
            hh, s, v = mf.hsv(src[y, x, :3])
            if s > 0.5 and 0.78 < hh < 0.85 and EYE_ROWS[0] <= y < EYE_ROWS[1]:
                mat[y, x] = "eye"
            elif (0.66 < hh < 0.76 and s > 0.25) or (s > 0.5 and 0.78 < hh < 0.85):
                mat[y, x] = "plate"
    mats = {"scale": nem.DRAGON_SCALE, "plate": nem.DRAGON_PLATE,
            "eye": nem.eye(0.88, emission=0.8)}
    return {stem: spec_of(mat, mats, src, "cloth", {"texel_px": 8, "strength": 16.0})}


FAMILIES = {"overlays": overlay_specs, "books": book_specs, "held": held_specs,
            "entities": entity_specs, "dragon": dragon_specs}


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
    if {"-h", "--help"} & set(sys.argv[1:]):
        print(__doc__)
        sys.exit(0)
    main()
