"""Specs for the zombie villagers, the illagers, the witch, the ravager and the vex.

Written the way mob_families.py writes the ridden mobs and pets: a part map
per model (which box each art texel is drawn on, from the model's faces),
a few rules per skin that read its own art (a colour that is a strap on
the body is a hand on an arm), and one material table per family, so the
same cloth is the same decision on every skin. The output is a full grid
with a legend in specs/mineclonia/<stem>.json, laid out like a hand written
spec; atlas.py reads that, not this.

    python3 tools/pbr/pbr_author/illager_families.py            # write every spec
    python3 tools/pbr/pbr_author/illager_families.py --check    # exit 1 if any differs
    python3 tools/pbr/pbr_author/illager_families.py zombie_villager

Zombie villagers stack like villagers (villager_zombie.lua):
mobs_mc_zombie_villager_base^<biome>^<profession>^<badge>, on
mobs_mc_villager_zombie.b3d. Their biome and profession overlays are the
villager's art with a few texels changed (the swamp hat line and the
cleric's cap painted in the zombie's green skin, the cleric's sleeves
running down the zombie's longer arms), so each takes the approved
villager overlay spec, its stack renamed, with the green texels as rotten
skin and any texel the villager art does not draw given the material of
the same colour elsewhere in the skin. The base is the villager base's
heights, so the overlays sit on it as they do on a villager: rotten skin
at 0.4 (mobs_mc_zombie's rotten micro at its halved strength), the eyes
and mouth empty sockets sunk well under it, matte.

The illagers (pillager, vindicator, evoker, illusioner) and the witch are
living faces, on the face rules of 2026-10-03: skin smoothness 0.25 under
a small dome (round 6) and a gentle edge roll (edge_lean 15), no pores,
the eyes flush with the skin (iris 0.01 under the white), iris smoothness
0.8 and sclera 0.6, no F0 boost. They are one layer each, so their main
surfaces stand near the top of the range like the zombie's and husk's.
"""

import colorsys
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402

GAME = "mineclonia"
SPECS = Path(__file__).resolve().parent / "specs" / GAME

# The villager's spec keys, which the farmer was approved on.
HUMAN = {
    "class": "cloth",
    "texel_px": 16,
    "strength": 12,
    "chamfer": 2,
    "face_edge": "bevel",
    "bevel_px": 3,
    "micro": "none",
}
# The cow's, for the ravager (mob_families.HEAD).
BEAST = {
    "class": "cloth",
    "texel_px": 16,
    "strength": 24.0,
    "chamfer": 2,
    "face_edge": "bevel",
    "bevel_px": 3,
    "bevel_depth": 0.07,
    "micro": "none",
}

STITCH = {"inset": 0.22, "length": 0.36, "gap": 0.18, "width": 0.07, "groove": 0.05,
          "depth": 0.06}

# --- living faces (2026-10-03) ---------------------------------------------------


def skin(base, smooth=0.25):
    return {"mode": "soft", "base": base, "span": 0.08, "detail": 0.25, "micro": "none",
            "smooth": smooth, "smooth_spread": 0.02, "scatter": 0.25, "soft_edge": 0.3,
            "round": 6, "edge_roll": 2.5, "edge_lean": 15, "roll_rough": 0.03}


def face(base):
    """Skin, nose, brow, eyes and mouth for a living face whose skin stands
    at base."""
    return {
        "skin": skin(base),
        "nose": skin(base, 0.3),
        "brow": {"mode": "flat", "base": round(base + 0.07, 3), "span": 0.0, "micro": "none",
                 "smooth": 0.2, "smooth_spread": 0.0},
        "white": {"mode": "flat", "base": base, "span": 0.0, "micro": "none", "smooth": 0.6,
                  "smooth_spread": 0.0},
        "iris": {"mode": "flat", "base": round(base - 0.01, 3), "span": 0.0, "micro": "none",
                 "smooth": 0.8, "smooth_spread": 0.0},
        "mouth": {"mode": "flat", "base": round(base - 0.03, 3), "span": 0.0, "micro": "none",
                  "smooth": 0.2, "smooth_spread": 0.0, "ride": True, "round": 6,
                  "edge_roll": 2.5, "edge_lean": 15, "roll_rough": 0.03},
    }


# --- clothes, as the villager's ------------------------------------------------


def linen(base, threads=5.0, wear=0.07):
    return {"mode": "flat", "base": base, "span": 0.0, "micro": "linen", "micro_strength": 2.2,
            "micro_params": {"threads": threads}, "smooth": 0.12, "smooth_spread": 0.0,
            "wear": wear, "texel_edge": 0.015}


def coarse(base, wear=0.06, smooth=0.12):
    return {"mode": "flat", "base": base, "span": 0.0, "micro": "coarse", "micro_strength": 1.8,
            "smooth": smooth, "smooth_spread": 0.0, "wear": wear, "texel_edge": 0.015}


def wool(base, smooth=0.1):
    return {"mode": "flat", "base": base, "span": 0.0, "micro": "wool", "micro_strength": 2.0,
            "smooth": smooth, "smooth_spread": 0.0, "texel_edge": 0.015}


def canvas(base, wear=0.06, smooth=0.14):
    return {"mode": "flat", "base": base, "span": 0.0, "micro": "canvas", "micro_strength": 1.8,
            "smooth": smooth, "smooth_spread": 0.0, "wear": wear, "texel_edge": 0.015}


def knit(base):
    return {"mode": "flat", "base": base, "span": 0.0, "micro": "knit", "micro_strength": 1.3,
            "smooth": 0.12, "smooth_spread": 0.0, "texel_edge": 0.015}


def weave(base, smooth=0.2):
    """Embroidered trim: a fine weave, a little smoother than the cloth."""
    return {"mode": "flat", "base": base, "span": 0.0, "micro": "weave", "micro_strength": 1.6,
            "micro_params": {"threads": 6.0, "slub": 0.1}, "smooth": smooth,
            "smooth_spread": 0.0, "texel_edge": 0.015}


def leather(base, smooth=0.4, wear=0.15, stitch=True):
    m = {"mode": "flat", "base": base, "span": 0.0, "micro": "leather", "smooth": smooth,
         "smooth_spread": 0.0, "wear": wear}
    if stitch:
        m["stitch"] = dict(STITCH)
    return m


def metal(base, smooth=0.5):
    return {"mode": "flat", "base": base, "span": 0.0, "micro": "metal_worn", "smooth": smooth,
            "smooth_spread": 0.0, "metal": True, "wear": 0.12}


# --- helpers -------------------------------------------------------------------


def hsv(rgb):
    return colorsys.rgb_to_hsv(*[float(c) for c in rgb])


def hexc(rgb):
    c = np.clip(np.round(np.asarray(rgb) * 255.0), 0, 255).astype(int)
    return "#%02x%02x%02x" % tuple(c)


def lum(rgb):
    return float(lib.luminance(np.asarray(rgb, np.float32)))


def inside(x, y, r):
    return r[0] <= x < r[2] and r[1] <= y < r[3]


def write(stem, spec, check_only):
    """Write the spec as the hand written ones are laid out; True if the
    file already said exactly this."""
    lines = ["{"]
    keys = list(spec)
    for i, k in enumerate(keys):
        comma = "," if i < len(keys) - 1 else ""
        v = spec[k]
        if k in ("materials", "variants"):
            lines.append(" %s: {" % json.dumps(k))
            mk = list(v)
            for j, name in enumerate(mk):
                lines.append("  %s: %s%s" % (json.dumps(name), json.dumps(v[name]),
                                             "," if j < len(mk) - 1 else ""))
            lines.append(" }" + comma)
        elif k == "grid":
            lines.append(' "grid": [')
            for j, row in enumerate(v):
                lines.append("  %s%s" % (json.dumps(row), "," if j < len(v) - 1 else ""))
            lines.append(" ]" + comma)
        else:
            lines.append(" %s: %s%s" % (json.dumps(k), json.dumps(v), comma))
    lines.append("}")
    text = "\n".join(lines) + "\n"
    p = SPECS / (stem + ".json")
    same = p.exists() and p.read_text() == text
    if not check_only and not same:
        p.write_text(text)
    return same


CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"


def to_spec(mat, materials, head, extra=None, src=None):
    """The spec for a material map: the first material is the grid's '.',
    the rest a character each, in the order given. Texels src does not
    draw take the first."""
    if src is not None:
        mat = np.where(src[..., 3] >= 0.5, mat, list(materials)[0]).astype(object)
    names = list(materials)
    unknown = set(mat.ravel()) - set(names)
    if unknown:
        raise ValueError("materials not declared: %s" % sorted(unknown))
    used = [n for n in names if (mat == n).any()]
    keep = [names[0]] + [n for n in used if n != names[0]]
    legend = {CHARS[i]: n for i, n in enumerate(keep[1:])}
    sym = {n: c for c, n in legend.items()}
    sym[names[0]] = "."
    spec = dict(head)
    spec.update(extra or {})
    spec["materials"] = {n: materials[n] for n in keep}
    spec["grid"] = ["".join(sym[m] for m in row) for row in mat]
    spec["legend"] = legend
    return spec


# --- the villager like layout (64 x 64) ---------------------------------------
# Every model here but the witch's extra hat, the ravager and the vex draws
# the villager's layout: the head (8 x 10 x 8) and its nose, a hood or hat
# layer over the head, the body, the legs, the arms (crossed, or one each),
# and a robe layer over the body and legs.

HUMAN_PARTS = [("nose", (24, 0, 32, 6)), ("head", (0, 0, 32, 18)), ("hood", (32, 0, 64, 18)),
               ("legs", (0, 18, 16, 38)), ("body", (16, 18, 44, 38)), ("arms", (40, 18, 64, 64)),
               ("robe", (0, 38, 28, 64))]
FRONT = (8, 8, 16, 18)


def human_part(x, y):
    for name, r in HUMAN_PARTS:
        if inside(x, y, r):
            return name
    return "other"


def face_features(src, mat):
    """The brow, eyes and mouth on the head's front face (8, 8)-(16, 18),
    at the rows every illager and the villager draw them: the brow on rows
    12 and 13, the eyes on 14 (white outside, iris inside), the mouth or
    its corners on 15 to 17, each darker than the skin around it."""
    drawn = src[..., 3] >= 0.5
    sk = [lum(src[y, x, :3]) for y in range(FRONT[1], FRONT[3]) for x in range(FRONT[0], FRONT[2])
          if drawn[y, x]]
    ref = float(np.median(sk))
    for y in range(FRONT[1], FRONT[3]):
        for x in range(FRONT[0], FRONT[2]):
            if not drawn[y, x]:
                continue
            L = lum(src[y, x, :3])
            if y in (12, 13) and L < 0.7 * ref:
                mat[y, x] = "brow"
            elif y == 14 and x in (9, 14) and L > 0.6:
                mat[y, x] = "white"
            elif y == 14 and x in (10, 13):
                mat[y, x] = "iris"
            elif 15 <= y <= 17 and L < 0.8 * ref:
                mat[y, x] = "mouth"


def classify(src, part_of, rule):
    """A material per texel: rule(part, rgb, x, y) for every drawn one."""
    h, w = src.shape[:2]
    mat = np.full((h, w), "skin", dtype=object)
    for y in range(h):
        for x in range(w):
            if src[y, x, 3] >= 0.5:
                mat[y, x] = rule(part_of(x, y), src[y, x, :3], x, y)
    return mat


# --- zombie villagers ----------------------------------------------------------

ZV_MODEL = "mobs_mc_villager_zombie.b3d"
ZV_BIOMES = ["desert", "jungle", "plains", "savanna", "snow", "swamp", "taiga"]
ZV_PROFESSIONS = ["armorer", "butcher", "cartographer", "cleric", "farmer", "fisherman",
                  "fletcher", "leatherworker", "librarian", "mason", "nitwit", "shepherd",
                  "toolsmith", "weaponsmith"]
ZV_BASE = "mobs_mc_zombie_villager_base"


def zv_stack(biome="plains", profession="farmer"):
    return [ZV_BASE, "mobs_mc_zombie_villager_" + biome,
            "mobs_mc_zombie_villager_profession_" + profession, "mobs_mc_stone"]


# Rotten skin: mobs_mc_zombie's rotten micro at its halved strength, on the
# villager base's height so the villager overlays stand on it as they do on
# a villager. The dome and roll are the family brief's undead (ROT).
ROT = {"mode": "soft", "base": 0.4, "span": 0.08, "detail": 0.25, "micro": "rotten",
       "micro_strength": 0.8, "smooth": 0.34, "smooth_spread": 0.02, "scatter": 0.2,
       "wear": 0.05, "soft_edge": 0.3, "round": 6, "edge_roll": 2.5, "edge_lean": 15,
       "roll_rough": 0.03}
ZV_MATERIALS = {
    "skin": ROT,
    "nose": dict(ROT, smooth=0.38),
    "brow": {"mode": "flat", "base": 0.47, "span": 0.0, "micro": "none", "smooth": 0.2,
             "smooth_spread": 0.0},
    # Empty: the art's pale and red eye texels are the socket's floor, matte.
    "socket": {"mode": "flat", "base": 0.1, "span": 0.0, "micro": "none", "smooth": 0.3,
               "smooth_spread": 0.0},
    # The villager base's robe and legs, a little more worn.
    "robe": coarse(0.44, wear=0.12),
    "legs": canvas(0.44, wear=0.12),
    "shoes": leather(0.52),
    # The plain zombie villager's long brown coat.
    "coat": coarse(0.48, wear=0.14, smooth=0.1),
}


def zv_green(rgb):
    h, s, v = hsv(rgb)
    return s > 0.25 and 0.2 < h < 0.45


def zv_rule(part, rgb, x, y):
    h, s, v = hsv(rgb)
    if part == "nose":
        return "nose"
    if part == "head":
        if y == 13 and 9 <= x <= 14 and not zv_green(rgb):
            return "brow"
        if y == 14 and x in (9, 10, 13, 14):
            return "socket"
        return "skin"
    if part == "body":
        # The tunic, its green mould stains part of the cloth.
        return "robe"
    if part in ("legs", "arms"):
        if zv_green(rgb):
            return "skin"
        if s < 0.06 and v >= 0.24:
            return "shoes" if part == "legs" else "robe"
        return "legs" if part == "legs" else "robe"
    if part == "robe":
        return "coat"
    return "robe"


def zombie_villager_base_specs():
    out = {}
    for stem, extra in ((ZV_BASE, {"stack": zv_stack()}), ("mobs_mc_zombie_villager", {})):
        src = lib.load_source(stem, GAME)
        mat = classify(src, human_part, zv_rule)
        out[stem] = to_spec(mat, ZV_MATERIALS, HUMAN, extra, src=src)
    return out


def zombie_overlay(vstem, zstem, stack):
    """The villager overlay's spec for the zombie's art: the stack renamed,
    green skin texels rotten skin, texels the villager does not draw given
    the material of the same colour elsewhere in the zombie's art."""
    vs = json.loads((SPECS / (vstem + ".json")).read_text())
    za = lib.load_source(zstem, GAME)
    va = lib.load_source(vstem, GAME)
    grid = [list(r) for r in vs["grid"]]
    legend = dict(vs["legend"])
    mats = dict(vs["materials"])
    h, w = za.shape[:2]
    zd = za[..., 3] >= 0.5
    vd = va[..., 3] >= 0.5
    skin_c = None
    for y in range(h):
        for x in range(w):
            if not zd[y, x]:
                continue
            if zv_green(za[y, x, :3]) and (not vd[y, x] or hexc(za[y, x, :3]) != hexc(va[y, x, :3])):
                if skin_c is None:
                    skin_c = next(c for c in CHARS if c not in legend)
                    legend[skin_c] = "skin"
                    mats["skin"] = ROT
                grid[y][x] = skin_c
    # Colour to grid character, from texels both images draw alike.
    by_colour = {}
    for y in range(h):
        for x in range(w):
            if zd[y, x] and vd[y, x] and grid[y][x] in legend:
                by_colour.setdefault(hexc(za[y, x, :3]), grid[y][x])
    for y in range(h):
        for x in range(w):
            if zd[y, x] and not vd[y, x] and grid[y][x] not in legend:
                c = hexc(za[y, x, :3])
                if c in by_colour:
                    grid[y][x] = by_colour[c]
                else:
                    # Nearest colour drawn alike.
                    best, bd = None, 9.0
                    for k, ch in by_colour.items():
                        rgb = np.array([int(k[i:i + 2], 16) for i in (1, 3, 5)]) / 255.0
                        d = float(np.abs(rgb - za[y, x, :3]).sum())
                        if d < bd:
                            best, bd = ch, d
                    grid[y][x] = best
    spec = {k: v for k, v in vs.items() if k not in ("materials", "grid", "legend", "stack")}
    # Keep the villager's key order, with the stack where it was.
    out = {}
    for k in vs:
        if k == "stack":
            out[k] = stack
        elif k == "materials":
            out[k] = mats
        elif k == "grid":
            out[k] = ["".join(r) for r in grid]
        elif k == "legend":
            out[k] = legend
        else:
            out[k] = spec[k]
    return out


# A villager's crossed arms hide its body's front; a zombie's held out arms
# do not. The belts these overlays draw across that face stood 0.12 to 0.22
# over the shirt, became the face's highest texels, and the shirt sank and
# slid under them at a 60 degree view (85% and 88% of the face's texels
# kept). On the zombie they rise half as far over the shirt.
ZV_BELTS = {"mobs_mc_zombie_villager_profession_cleric": ("belt", "buckle"),
            "mobs_mc_zombie_villager_snow": ("beltleather", "toggle")}
ZV_SHIRT = 0.46


def zombie_villager_overlay_specs():
    out = {}
    for b in ZV_BIOMES:
        out["mobs_mc_zombie_villager_" + b] = zombie_overlay(
            "mobs_mc_villager_" + b, "mobs_mc_zombie_villager_" + b, zv_stack(biome=b))
    for p in ZV_PROFESSIONS:
        out["mobs_mc_zombie_villager_profession_" + p] = zombie_overlay(
            "mobs_mc_villager_profession_" + p, "mobs_mc_zombie_villager_profession_" + p,
            zv_stack(profession=p))
    for stem, names in ZV_BELTS.items():
        mats = out[stem]["materials"]
        for n in names:
            m = dict(mats[n])
            m["base"] = round(ZV_SHIRT + (m["base"] - ZV_SHIRT) * 0.5, 3)
            mats[n] = m
    return out


def zombie_villager_specs():
    out = zombie_villager_base_specs()
    out.update(zombie_villager_overlay_specs())
    return out


# --- illagers ------------------------------------------------------------------
# One layer each, so the main surfaces stand near the top of the range.

ILL_B = 0.84


def illager_materials(**cloth):
    m = face(ILL_B)
    m.update(cloth)
    return m


def blueish(rgb):
    h, s, v = hsv(rgb)
    return 0.5 <= h <= 0.7 and s >= 0.15


def pillager_rule(part, rgb, x, y):
    h, s, v = hsv(rgb)
    maroon = s > 0.2 and (h > 0.9 or h < 0.02)
    brown = s > 0.3 and 0.04 <= h <= 0.12
    if part == "nose":
        return "nose"
    if part == "head":
        return "skin"
    if part == "legs":
        if 0.4 <= h <= 0.6 and s > 0.3:
            return "trousers"
        return "boot"
    if part == "body":
        if maroon:
            return "jacket"
        if brown:
            return "strap"
        if s < 0.05 and v >= 0.3:
            return "shirt"
        return "belt"
    if part == "arms":
        if maroon:
            return "jacket"
        if brown:
            return "strap"
        if s <= 0.01 and v >= 0.3:
            return "skin"
        if s > 0.02 and v > 0.5:
            return "pad"
        return "bracer"
    if part == "robe":
        if 0.08 <= h <= 0.18 and s > 0.3 and v > 0.6:
            return "buckle"
        if maroon:
            return "jacket"
        return "belt"
    return "jacket"


PILLAGER = illager_materials(
    jacket=coarse(0.9),
    shirt=linen(0.92),
    strap=leather(0.95, smooth=0.42, wear=0.12),
    pad=wool(0.94),
    bracer=leather(0.93, smooth=0.36, stitch=False),
    trousers=canvas(0.88),
    boot=leather(0.92),
    belt=leather(0.96, smooth=0.42, wear=0.12),
    buckle=metal(1.0),
)


def vindicator_rule(part, rgb, x, y):
    h, s, v = hsv(rgb)
    if part == "nose":
        return "nose"
    if part == "head":
        return "skin"
    if part == "legs":
        return "trousers" if blueish(rgb) else "boot"
    if part == "body":
        if v >= 0.3:
            return "collar"
        return "jacket"
    if part == "arms":
        if v >= 0.35 and s < 0.05:
            return "skin"
        return "coat"
    if part == "robe":
        return "coat"
    return "jacket"


VINDICATOR = illager_materials(
    jacket=canvas(0.9),
    collar=linen(0.92),
    coat=coarse(0.92, wear=0.08, smooth=0.1),
    trousers=canvas(0.88, smooth=0.16),
    boot=leather(0.92),
)


def evoker_rule(part, rgb, x, y):
    h, s, v = hsv(rgb)
    green = 0.18 <= h <= 0.42 and s > 0.4
    if part == "nose":
        return "nose"
    if part == "head":
        return "skin"
    if part == "legs":
        return "trousers" if blueish(rgb) else "boot"
    if green:
        return "trim"
    if part == "body":
        return "collar" if v >= 0.3 else "robe"
    if part == "arms":
        return "skin" if (v >= 0.38 and s < 0.05) else "robe"
    return "robe"


EVOKER = illager_materials(
    robe=coarse(0.92, smooth=0.1),
    trim=weave(0.92, smooth=0.24),
    collar=linen(0.92),
    trousers=canvas(0.88, smooth=0.16),
    boot=leather(0.92),
)


def illusioner_rule(part, rgb, x, y):
    h, s, v = hsv(rgb)
    star = (s < 0.1 and v > 0.5) or (0.1 <= h <= 0.25 and s > 0.2 and v > 0.5)
    if part == "nose":
        return "nose"
    if part == "head":
        return "skin"
    if part == "legs":
        return "trousers"
    if star and part in ("hood", "arms", "robe", "body"):
        return "star"
    if part == "hood":
        return "hood"
    if part == "body":
        return "collar" if s < 0.1 else "robe"
    if part == "arms":
        return "skin" if s < 0.1 else "robe"
    return "robe"


ILLUSIONER = illager_materials(
    hood=wool(0.92),
    robe=coarse(0.9, smooth=0.1),
    star={"mode": "flat", "base": 0.93, "span": 0.0, "micro": "none", "smooth": 0.42,
          "smooth_spread": 0.0},
    collar=linen(0.92),
    trousers=canvas(0.88, smooth=0.16),
)


def illager(stem, rule, materials):
    src = lib.load_source(stem, GAME)
    mat = classify(src, human_part, rule)
    face_features(src, mat)
    return to_spec(mat, materials, HUMAN, src=src)


def illager_specs():
    return {
        "mobs_mc_pillager": illager("mobs_mc_pillager", pillager_rule, PILLAGER),
        "mobs_mc_vindicator": illager("mobs_mc_vindicator", vindicator_rule, VINDICATOR),
        "mobs_mc_evoker": illager("mobs_mc_evoker", evoker_rule, EVOKER),
        "mobs_mc_illusionist": illager("mobs_mc_illusionist", illusioner_rule, ILLUSIONER),
    }


# --- the witch (64 x 128) -------------------------------------------------------
# The villager layout plus a three tier hat (0, 64)-(40, 98) and a wart box
# at (0, 0)-(4, 2), which the art leaves undrawn.

WITCH_PARTS = [("wart", (0, 0, 4, 2))] + HUMAN_PARTS + [("hat", (0, 64, 40, 98))]


def witch_part(x, y):
    for name, r in WITCH_PARTS:
        if inside(x, y, r):
            return name
    return "other"


def witch_rule(part, rgb, x, y):
    h, s, v = hsv(rgb)
    gem = s > 0.12 and 0.3 <= h <= 0.55
    if gem:
        return "gem"
    if part in ("nose", "wart"):
        return "nose"
    if part == "head":
        if inside(x, y, FRONT):
            if y in (11, 12) and 9 <= x <= 14 and v < 0.36:
                return "brow"
            if y == 15 and x in (10, 13):
                return "iris"
        return "skin"
    if part == "hat":
        return "hat"
    if part == "robe":
        return "robe"
    if part == "legs":
        if y >= 36 or inside(x, y, (8, 22, 12, 26)):
            return "shoe"
        return "dress"
    return "dress"


WITCH = face(ILL_B)
WITCH.update(
    gem={"mode": "flat", "base": 0.86, "span": 0.0, "micro": "none", "smooth": 0.62,
         "smooth_spread": 0.0},
    hat=wool(0.92, smooth=0.08),
    robe=coarse(0.92, smooth=0.1, wear=0.1),
    dress=linen(0.9, threads=4.0, wear=0.1),
    shoe=leather(0.94),
)


def witch_specs():
    src = lib.load_source("mobs_mc_witch", GAME)
    mat = classify(src, witch_part, witch_rule)
    return {"mobs_mc_witch": to_spec(mat, WITCH, HUMAN, src=src)}


# --- the ravager (128 x 128) ----------------------------------------------------
# Boxes from mobs_mc_ravager.b3d's faces: the head (16, 0)-(64, 36), its
# jaw (16, 36)-(48, 52) and (0, 52)-(64, 55), the snout (0, 0)-(16, 12),
# the horn (74, 55)-(86, 73), the legs (64, 0)-(128, 45), the neck
# (68, 73)-(124, 101), the body (0, 55)-(68, 91) and the haunch
# (0, 91)-(60, 122).

RAV_PARTS = [("horn", (74, 55, 86, 73)), ("snout", (0, 0, 16, 12)), ("head", (16, 0, 64, 36)),
             ("head", (16, 36, 48, 52)), ("head", (0, 52, 64, 55)), ("legs", (64, 0, 128, 45)),
             ("neck", (68, 73, 124, 101)), ("body", (0, 55, 68, 91)),
             ("body", (0, 91, 60, 122))]


def ravager_part(x, y):
    for name, r in RAV_PARTS:
        if inside(x, y, r):
            return name
    return "other"


def ravager_rule(part, rgb, x, y):
    h, s, v = hsv(rgb)
    if part == "horn":
        return "horn"
    if s > 0.9:
        return "eye"
    if part == "head" and 0.07 <= h <= 0.11 and 0.27 <= s <= 0.4 and 0.4 <= v <= 0.7:
        return "teeth"
    if s > 0.35 and (h < 0.03 or h > 0.97):
        return "strap"
    if s > 0.4 and 0.05 <= h <= 0.11 and 78 <= y <= 90:
        return "saddle"
    if (s >= 0.2 and v >= 0.6) or (s < 0.2 and v >= 0.42):
        return "callus"
    if part == "snout":
        return "snout"
    return "hide"


RAVAGER = {
    # Thick hide by shade, the dark framing lines lower, waxy and creased.
    "hide": {"mode": "shade", "base": 0.78, "span": 0.14, "levels": 3, "detail": 0.25,
             "joints": False, "smooth": 0.3, "smooth_spread": 0.04, "micro": "hide",
             "micro_params": {"cell": 0.45, "wrinkles": 1.0}, "micro_strength": 0.35,
             "scatter": 0.15},
    # The pale patches: hard calloused plates, proud of the hide.
    "callus": {"mode": "flat", "base": 0.9, "span": 0.0, "micro": "bone", "smooth": 0.38,
               "smooth_spread": 0.0, "micro_strength": 0.6, "micro_params": {"cracks": 0.5}},
    "horn": {"mode": "flat", "base": 0.96, "span": 0.0, "micro": "bone", "smooth": 0.45,
             "smooth_spread": 0.0, "micro_strength": 1.2, "micro_params": {"cracks": 0.8}},
    "teeth": {"mode": "flat", "base": 0.94, "span": 0.0, "micro": "bone", "smooth": 0.55,
              "smooth_spread": 0.0, "micro_strength": 0.2, "micro_params": {"cracks": 0.2}},
    "eye": {"mode": "flat", "base": 0.78, "span": 0.0, "micro": "none", "smooth": 0.8,
            "smooth_spread": 0.0},
    "snout": {"mode": "flat", "base": 0.9, "span": 0.0, "micro": "hide", "smooth": 0.45,
              "smooth_spread": 0.0, "micro_params": {"cell": 0.35, "wrinkles": 1.2},
              "micro_strength": 0.3, "scatter": 0.2},
    # The saddle's girth and seat (mob_families' LEATHER and SEAT).
    "strap": {"mode": "flat", "base": 0.92, "span": 0.0, "micro": "leather", "smooth": 0.38,
              "smooth_spread": 0.0, "micro_strength": 0.4,
              "stitch": dict(STITCH, depth=0.03), "wear": 0.15},
    "saddle": {"mode": "flat", "base": 0.94, "span": 0.0, "micro": "leather", "smooth": 0.5,
               "smooth_spread": 0.0, "micro_strength": 0.3, "wear": 0.2},
}


def ravager_specs():
    src = lib.load_source("mobs_mc_ravager", GAME)
    mat = classify(src, ravager_part, ravager_rule)
    return {"mobs_mc_ravager": to_spec(mat, RAVAGER, BEAST, src=src)}


# --- the vex (64 x 64) ----------------------------------------------------------
# mobs_mc_vex.b3d: the head (0, 0)-(32, 16) with its front at (8, 8)-(16, 16),
# the body (16, 16)-(40, 32), the arms (40, 16)-(56, 32), the tapering tail
# (32, 0)-(52, 16) and one wing quad (0, 32)-(22, 46).

VEX_PARTS = [("head", (0, 0, 32, 16)), ("tail", (32, 0, 56, 16)), ("body", (16, 16, 40, 32)),
             ("arms", (40, 16, 56, 32)), ("wing", (0, 32, 22, 46))]
VEX_FRONT = (8, 8, 16, 16)


def vex_part(x, y):
    for name, r in VEX_PARTS:
        if inside(x, y, r):
            return name
    return "other"


def vex_rule(part, rgb, x, y):
    h, s, v = hsv(rgb)
    if part == "wing":
        return "wing"
    if part == "head" and inside(x, y, VEX_FRONT):
        if v > 0.95 and s < 0.05:
            return "white"
        if v > 0.95 and s >= 0.2:
            return "mouth"
        if y in (10, 11):
            return "brow"
    red = s >= 0.45 and (h < 0.05 or h > 0.95)
    if red or (s >= 0.4 and v >= 0.5):
        return "vein"
    if part == "arms" and s < 0.05:
        return "hand"
    return "spirit"


VEX_B = 0.84
VEX = {
    # Spectral: soft, a little glossy, scattering, no pores.
    "spirit": dict(skin(VEX_B, 0.5), scatter=0.5),
    "vein": {"mode": "flat", "base": round(VEX_B - 0.02, 3), "span": 0.0, "micro": "none",
             "smooth": 0.6, "smooth_spread": 0.0, "scatter": 0.5},
    "brow": {"mode": "flat", "base": round(VEX_B + 0.07, 3), "span": 0.0, "micro": "none",
             "smooth": 0.3, "smooth_spread": 0.0, "scatter": 0.3},
    "white": {"mode": "flat", "base": VEX_B, "span": 0.0, "micro": "none", "smooth": 0.6,
              "smooth_spread": 0.0},
    "mouth": {"mode": "flat", "base": round(VEX_B - 0.03, 3), "span": 0.0, "micro": "none",
              "smooth": 0.7, "smooth_spread": 0.0, "scatter": 0.6},
    "hand": dict(skin(round(VEX_B + 0.02, 3), 0.45), scatter=0.4),
    # The wings: one thin quad, its own material, a faint vane.
    "wing": {"mode": "flat", "base": 0.9, "span": 0.0, "micro": "feather",
             "micro_strength": 0.4, "smooth": 0.45, "smooth_spread": 0.0, "scatter": 0.6},
}


def vex_specs():
    out = {}
    for stem in ("mobs_mc_vex", "mobs_mc_vex_charging"):
        src = lib.load_source(stem, GAME)
        mat = classify(src, vex_part, vex_rule)
        out[stem] = to_spec(mat, VEX, HUMAN, src=src)
    return out


# The face studies the default build ignores (README, "Sculpted faces" and
# "Crisp sculpted faces"): GOANNA_PBR_VARIANT=<name> lays one over the spec.
# They were first written into the specs by hand, so a regeneration dropped
# them; they live here now and are written as each spec's last key.
VARIANTS = {
    "mobs_mc_zombie_villager_base": {
        "sculpt": {
            "materials": {
                "skin": {"span": 0.22, "round": 4},
                "nose": {"span": 0.22, "round": 4},
                "brow": {"flush": {"to": ["skin", "nose"], "offset": 0.06}},
            },
        },
    },
    "mobs_mc_pillager": {
        "sculpt": {
            "materials": {
                "skin": {"span": 0.22, "round": 4},
                "nose": {"span": 0.22, "round": 4},
                "brow": {"flush": {"to": ["skin", "nose"], "offset": 0.06}},
                "white": {"flush": {"to": ["skin", "nose"], "group": "eye"}},
                "iris": {"flush": {"to": ["skin", "nose"], "group": "eye", "offset": -0.01}},
                "mouth": {"flush": {"to": ["skin", "nose"], "offset": -0.04}},
            },
        },
        "sculpt_crisp": {
            "legend": {
                "a": "nose",
                "b": "brow",
                "c": "eye",
                "d": "eye",
                "e": "mouth",
                "f": "jacket",
                "g": "shirt",
                "h": "strap",
                "i": "pad",
                "j": "bracer",
                "k": "trousers",
                "l": "boot",
                "m": "belt",
                "n": "buckle",
            },
            "rects": [
                ["earhole", 3, 13, 5, 14],
                ["earhole", 3, 14, 4, 15],
                ["earhole", 19, 13, 21, 14],
                ["earhole", 20, 14, 21, 15],
                ["brow", 7, 12, 8, 14],
                ["brow", 16, 12, 17, 14],
            ],
            "materials": {
                "skin": {
                    "mode": "shade",
                    "base": 0.65,
                    "span": 0.3,
                    "levels": 3,
                    "detail": 0.25,
                    "merge": 0.2,
                    "joints": False,
                    "soft_edge": None,
                    "ride": True,
                    "round": 4,
                    "edge_roll": 2.5,
                    "edge_lean": 15,
                },
                "nose": {
                    "mode": "shade",
                    "base": 0.65,
                    "span": 0.3,
                    "levels": 3,
                    "detail": 0.25,
                    "merge": 0.2,
                    "joints": False,
                    "soft_edge": None,
                    "ride": True,
                    "round": 4,
                    "edge_roll": 2.5,
                    "edge_lean": 15,
                },
                "brow": {
                    "flush": {"to": ["skin", "nose"], "offset": 0.08},
                    "ride": True,
                    "round": 4,
                    "edge_roll": 2.5,
                    "edge_lean": 15,
                    "roll_rough": 0.03,
                },
                "eye": {
                    "mode": "soft",
                    "base": 0.5,
                    "span": 0.0,
                    "detail": 0.0,
                    "soft_edge": 0.0,
                    "micro": "bulge",
                    "micro_params": {"lean": 6.0},
                    "smooth": 0.7,
                    "smooth_spread": -0.2,
                    "flush": {"to": ["skin", "nose"], "group": "eye"},
                    "ride": True,
                    "round": 4,
                    "edge_roll": 2.5,
                    "edge_lean": 15,
                    "roll_rough": 0.03,
                },
                "mouth": {"flush": {"to": ["skin", "nose"], "offset": -0.1}, "round": 4},
                "earhole": {
                    "mode": "flat",
                    "base": 0.55,
                    "span": 0.0,
                    "micro": "none",
                    "smooth": 0.2,
                    "smooth_spread": 0.0,
                    "ride": True,
                    "round": 4,
                    "edge_roll": 2.5,
                    "edge_lean": 15,
                    "roll_rough": 0.03,
                },
            },
        },
    },
    "mobs_mc_vindicator": {
        "sculpt": {
            "materials": {
                "skin": {"span": 0.22, "round": 4},
                "nose": {"span": 0.22, "round": 4},
                "brow": {"flush": {"to": ["skin", "nose"], "offset": 0.06}},
                "white": {"flush": {"to": ["skin", "nose"], "group": "eye"}},
                "iris": {"flush": {"to": ["skin", "nose"], "group": "eye", "offset": -0.01}},
                "mouth": {"flush": {"to": ["skin", "nose"], "offset": -0.04}},
            },
        },
        "sculpt_crisp": {
            "legend": {
                "a": "nose",
                "b": "brow",
                "c": "eye",
                "d": "eye",
                "e": "mouth",
                "f": "jacket",
                "g": "collar",
                "h": "coat",
                "i": "trousers",
                "j": "boot",
            },
            "rects": [["earhole", 4, 14, 6, 16], ["earhole", 18, 14, 20, 16]],
            "materials": {
                "skin": {
                    "mode": "shade",
                    "base": 0.65,
                    "span": 0.3,
                    "levels": 3,
                    "detail": 0.25,
                    "merge": 0.2,
                    "joints": False,
                    "soft_edge": None,
                    "ride": True,
                    "round": 4,
                    "edge_roll": 2.5,
                    "edge_lean": 15,
                },
                "nose": {
                    "mode": "shade",
                    "base": 0.65,
                    "span": 0.3,
                    "levels": 3,
                    "detail": 0.25,
                    "merge": 0.2,
                    "joints": False,
                    "soft_edge": None,
                    "ride": True,
                    "round": 4,
                    "edge_roll": 2.5,
                    "edge_lean": 15,
                },
                "brow": {
                    "flush": {"to": ["skin", "nose"], "offset": 0.08},
                    "ride": True,
                    "round": 4,
                    "edge_roll": 2.5,
                    "edge_lean": 15,
                    "roll_rough": 0.03,
                },
                "eye": {
                    "mode": "soft",
                    "base": 0.5,
                    "span": 0.0,
                    "detail": 0.0,
                    "soft_edge": 0.0,
                    "micro": "bulge",
                    "micro_params": {"lean": 6.0},
                    "smooth": 0.7,
                    "smooth_spread": -0.2,
                    "flush": {"to": ["skin", "nose"], "group": "eye"},
                    "ride": True,
                    "round": 4,
                    "edge_roll": 2.5,
                    "edge_lean": 15,
                    "roll_rough": 0.03,
                },
                "mouth": {"flush": {"to": ["skin", "nose"], "offset": -0.1}, "round": 4},
                "earhole": {
                    "mode": "flat",
                    "base": 0.55,
                    "span": 0.0,
                    "micro": "none",
                    "smooth": 0.2,
                    "smooth_spread": 0.0,
                    "ride": True,
                    "round": 4,
                    "edge_roll": 2.5,
                    "edge_lean": 15,
                    "roll_rough": 0.03,
                },
            },
        },
    },
    "mobs_mc_evoker": {
        "sculpt": {
            "materials": {
                "skin": {"span": 0.22, "round": 4},
                "nose": {"span": 0.22, "round": 4},
                "brow": {"flush": {"to": ["skin", "nose"], "offset": 0.06}},
                "white": {"flush": {"to": ["skin", "nose"], "group": "eye"}},
                "iris": {"flush": {"to": ["skin", "nose"], "group": "eye", "offset": -0.01}},
                "mouth": {"flush": {"to": ["skin", "nose"], "offset": -0.04}},
            },
        },
    },
}


FAMILIES = {
    "zombie_villager": zombie_villager_specs,
    "illager": illager_specs,
    "witch": witch_specs,
    "ravager": ravager_specs,
    "vex": vex_specs,
}

# The model and brush of each stem, for stems/mineclonia.mobs.txt.
MODELS = {
    "mobs_mc_pillager": ("mobs_mc_pillager.b3d", None),
    "mobs_mc_vindicator": ("mobs_mc_vindicator.b3d", None),
    "mobs_mc_evoker": ("mobs_mc_evoker.b3d", None),
    "mobs_mc_illusionist": ("mobs_mc_illusioner.b3d", None),
    "mobs_mc_witch": ("mobs_mc_witch.b3d", None),
    "mobs_mc_ravager": ("mobs_mc_ravager.b3d", None),
    "mobs_mc_vex": ("mobs_mc_vex.b3d", -1),
    "mobs_mc_vex_charging": ("mobs_mc_vex.b3d", -1),
}


def model_of(stem):
    if stem.startswith("mobs_mc_zombie_villager"):
        return ZV_MODEL, None
    return MODELS[stem]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check_only = "--check" in sys.argv
    lines = "--lines" in sys.argv
    stale = []
    for name in args or list(FAMILIES):
        for stem, spec in FAMILIES[name]().items():
            if lines:
                m, b = model_of(stem)
                print("%s %s%s" % (stem, m, "" if b is None else " %d" % b))
                continue
            if stem in VARIANTS:
                spec = {**spec, "variants": VARIANTS[stem]}
            if not write(stem, spec, check_only):
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
