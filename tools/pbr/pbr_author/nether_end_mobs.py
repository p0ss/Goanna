"""Specs for the Nether, End and boss mobs, and the shulkers.

The piglins, hoglins, striders, blaze, ghast, magma cube, ender dragon,
wither, endermite, silverfish, guardians and shulkers. Each is a model
atlas (atlas.py), so like mob_families.py this writes a full grid per
stem from a part map and a few colour rules, and the materials are one
table per family below, judged once for every skin that shares them:

  part map   face rectangles read from each model with atlas.faces (the
             tusks, the snout, the mane, a leg box), written out below.
  rules      per texel, from the art: the red of a piglin's skin, the gold
             of its rings, the pink of a hoglin's snout, the bright texels
             of a glowing core. The undead variants reuse the living art's
             layout where their own art no longer tells the parts apart
             (the zoglin's snout is the hoglin's, the invulnerable
             wither's sockets are the wither's).
  materials  per family, in the house style settled with the owner:
             shallow shade steps inside a material, main surfaces near the
             top of the range, deep pits only where the art draws a hole,
             soft skin rolled at its box edges, living eyes flat and flush
             (iris smoothness 0.8, sclera 0.6, no F0 boost), the undead's
             sockets sunk half the range, glow from the bright texels of
             the parts that burn.

The shulkers were built by extrude.py as tiling blocks until 2026-10-03;
their skins are model atlases of a shell (plates like purpur, the dark
outline of each plate a sunk seam) around a soft head.

    python3 tools/pbr/pbr_author/nether_end_mobs.py            # write every spec
    python3 tools/pbr/pbr_author/nether_end_mobs.py --check    # exit 1 if any differs
    python3 tools/pbr/pbr_author/nether_end_mobs.py piglin     # one family

The model and brush each stem is drawn with are in MODELS; atlas.py needs
them on the command line until the stem is in stems/mineclonia.mobs.txt.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import mob_families as mf  # noqa: E402

GAME = "mineclonia"

SHULKER_COLOURS = ("black", "blue", "brown", "cyan", "gray", "green", "light_blue", "lime",
                   "magenta", "orange", "pink", "purple", "red", "silver", "white", "yellow")

# stem: (model, brush). The guardian, blaze, ghast and dragon models draw
# with no brush (-1), as the spider's does.
MODELS = {
    "extra_mobs_piglin": ("mobs_mc_piglin.b3d", 0),
    "extra_mobs_piglin_brute": ("mobs_mc_piglin.b3d", 0),
    "extra_mobs_zombified_piglin": ("mobs_mc_piglin.b3d", 0),
    "extra_mobs_hoglin": ("extra_mobs_hoglin.b3d", 0),
    "extra_mobs_zoglin": ("extra_mobs_hoglin.b3d", 0),
    "extra_mobs_strider": ("extra_mobs_strider.b3d", 0),
    "extra_mobs_strider_cold": ("extra_mobs_strider.b3d", 0),
    "mobs_mc_blaze": ("mobs_mc_blaze.b3d", -1),
    "mobs_mc_ghast": ("mobs_mc_ghast.b3d", -1),
    "mobs_mc_ghast_firing": ("mobs_mc_ghast.b3d", -1),
    "mobs_mc_magmacube": ("mobs_mc_magmacube.b3d", 0),
    "mobs_mc_dragon": ("mobs_mc_dragon.b3d", -1),
    "mobs_mc_wither": ("mobs_mc_wither.b3d", 0),
    "mobs_mc_wither_invulnerable": ("mobs_mc_wither.b3d", 0),
    "mobs_mc_wither_armor": ("mobs_mc_wither.b3d", 1),
    "mobs_mc_endermite": ("mobs_mc_endermite.b3d", 0),
    "mobs_mc_silverfish": ("mobs_mc_silverfish.b3d", 0),
    "mobs_mc_guardian": ("mobs_mc_guardian.b3d", -1),
    "mobs_mc_guardian_elder": ("mobs_mc_guardian.b3d", -1),
    "mobs_mc_endergolem": ("mobs_mc_shulker.b3d", 0),
}
for _c in SHULKER_COLOURS:
    MODELS["mobs_mc_shulker_" + _c] = ("mobs_mc_shulker.b3d", 0)

# The stem keys every family shares: the cow's, which the owner approved.
HEAD = {k: v for k, v in mf.HEAD.items() if k != "class"}

# --- shared materials -----------------------------------------------------------


def eye(base, smooth=0.8, **kw):
    """A living eye: flat, flush with the skin around it, glossy, no micro
    and no F0 above a dielectric's. smooth 0.8 for an iris or a pupil, 0.6
    for the white."""
    m = {"mode": "flat", "base": base, "span": 0.0, "micro": "none", "smooth": smooth,
         "smooth_spread": 0.0, "scatter": 0}
    m.update(kw)
    return m


def pit(base, smooth=0.3, **kw):
    """A hole the art draws: an undead socket, an open mouth. Flat, matte."""
    m = {"mode": "flat", "base": base, "span": 0.0, "micro": "none", "smooth": smooth,
         "smooth_spread": 0.0, "scatter": 0}
    m.update(kw)
    return m


def glow(base, emission, smooth=0.55, **kw):
    """A burning part: one flat height per shade band, emitting by band so
    the brightest texels glow most and the pattern stays."""
    m = {"mode": "flat", "base": base, "span": 0.0, "micro": "none", "smooth": smooth,
         "smooth_spread": 0.0, "scatter": 0, "emission": emission}
    m.update(kw)
    return m


# Living skin: soft, lighter a little higher, rolled at the box edges. The
# face rules of 2026-10-03: smoothness 0.25, the dome halved, the roll
# leaning 10 degrees. An animal's hide keeps its creases; the ghast's and
# the shulker's bare skin has no pores.
SKIN = {"mode": "soft", "base": 0.9, "span": 0.08, "detail": 0.25, "soft_edge": 0.3, "round": 3,
        "edge_roll": 2, "edge_lean": 10, "roll_rough": 0.03, "smooth": 0.25, "smooth_spread": 0.02,
        "micro": "hide", "micro_params": {"cell": 0.8, "wrinkles": 0.6}, "micro_strength": 0.5,
        "scatter": 0.3, "wear": 0.05}
# The undead's skin, as the zombie's since the face rules: rotten's pits off.
ROT = {"mode": "soft", "base": 0.92, "span": 0.08, "detail": 0.25, "micro": "rotten",
       "micro_strength": 0.8, "smooth": 0.25, "smooth_spread": 0.02, "scatter": 0.2, "wear": 0.05,
       "soft_edge": 0.3, "round": 5, "edge_roll": 2.5, "edge_lean": 12, "roll_rough": 0.03,
       "micro_params": {"pits": 0.0}}
# Bone showing through, one flat piece a little under the skin it breaks.
BARE = {"mode": "flat", "base": 0.86, "span": 0.0, "micro": "bone", "micro_strength": 1.2,
        "micro_params": {"cracks": 0.6}, "smooth": 0.42, "smooth_spread": 0.0}
TUSK = {"mode": "flat", "base": 0.96, "span": 0.0, "micro": "bone", "micro_strength": 0.4,
        "micro_params": {"cracks": 0.3}, "smooth": 0.5, "smooth_spread": 0.0}
# Worn gold: rings, bracelets, a belt. Lighter higher by a shallow step.
GOLD = {"mode": "shade", "base": 0.86, "span": 0.12, "levels": 2, "detail": 0.3, "joints": False,
        "metal": True, "smooth": 0.62, "smooth_spread": 0.03, "micro": "metal_worn", "wear": 0.12}
SNOUT = {"mode": "flat", "base": 0.96, "span": 0.0, "micro": "hide", "smooth": 0.5,
         "smooth_spread": 0.0, "micro_params": {"cell": 0.4, "wrinkles": 1.2},
         "micro_strength": 0.3, "scatter": 0.25, "wear": 0.05}
NOSTRIL = pit(0.66, smooth=0.55)
LEATHER = {"mode": "flat", "base": 0.9, "span": 0.0, "micro": "leather", "smooth": 0.32,
           "smooth_spread": 0.0, "micro_strength": 0.4, "wear": 0.12}
STRAP = {"mode": "flat", "base": 0.96, "span": 0.0, "micro": "leather", "smooth": 0.38,
         "smooth_spread": 0.0, "micro_strength": 0.35, "wear": 0.12,
         "stitch": {"inset": 0.22, "length": 0.36, "gap": 0.18, "width": 0.07, "groove": 0.05,
                    "depth": 0.03}}

# --- helpers -----------------------------------------------------------------------


def inside(x, y, rects):
    return any(x0 <= x < x1 and y0 <= y < y1 for x0, y0, x1, y1 in rects)


def texels(src):
    """(x, y, rgb, h, s, v, luminance) for every drawn texel."""
    drawn = src[..., 3] >= 0.5
    for y, x in zip(*np.nonzero(drawn)):
        rgb = src[y, x, :3]
        h, s, v = mf.hsv(rgb)
        yield int(x), int(y), rgb, h, s, v, mf.lum(rgb)


def hexes(src):
    """Per texel '#rrggbb'."""
    q = np.clip(np.round(src[..., :3] * 255.0), 0, 255).astype(int)
    return np.array([["#%02x%02x%02x" % tuple(q[y, x]) for x in range(q.shape[1])]
                     for y in range(q.shape[0])], dtype=object)


def spec_of(mat, materials, src, cls, extra=None):
    e = dict(HEAD)
    e["class"] = cls
    e.update(extra or {})
    spec = mf.to_spec(mat, materials, None, src)
    # to_spec lays out the cow's keys; ours go first, as written by hand.
    out = dict(e)
    out.update({k: v for k, v in spec.items() if k in ("materials", "grid", "legend")})
    return out


def load(stem):
    return lib.load_source(stem, GAME)


# --- piglins ----------------------------------------------------------------------
# mobs_mc_piglin.b3d, brush 0 (1 and 2 are armour, blank). The head box is
# 10 x 8 x 8, the snout its own box in front, the tusks two small boxes,
# the ears flat boxes with a gold ring each.

P_TUSKS = [(2, 0, 6, 7)]
P_SNOUT = [(31, 1, 41, 6)]
P_EARS = [(39, 6, 61, 15)]
P_HEAD = [(0, 0, 36, 16)]
P_EYES = [(9, 11), (10, 11), (15, 11), (16, 11)]
# Strap colours the piglins share: the chest straps and the belt rope.
P_STRAP = {"#826853", "#99856b", "#b7a892", "#c8bfaa"}
# Bone colours the zombified piglin shows through its skin.
P_BONE = {"#f7eac8", "#e2cfaa", "#ccb396", "#9e8979", "#7c675d", "#3d3430"}

PIG_SKIN = SKIN
PIG_EYE = eye(0.9)
PIG_HOOD = {"mode": "shade", "base": 0.82, "span": 0.12, "levels": 2, "detail": 0.3,
            "joints": False, "micro": "coarse", "micro_strength": 0.9, "smooth": 0.2,
            "smooth_spread": 0.02, "wear": 0.12, "scatter": 0.1}
PIG_STUD = {"mode": "flat", "base": 0.98, "span": 0.0, "micro": "glass", "micro_strength": 0.3,
            "smooth": 0.8, "smooth_spread": 0.0, "f0": 0.1}


def piglin_specs():
    out = {}
    for stem in ("extra_mobs_piglin", "extra_mobs_piglin_brute", "extra_mobs_zombified_piglin"):
        src = load(stem)
        hx = hexes(src)
        h, w = src.shape[:2]
        zombie = "zombified" in stem
        brute = "brute" in stem
        mat = np.full((h, w), "skin", dtype=object)
        for x, y, rgb, hh, s, v, L in texels(src):
            c = hx[y, x]
            red = s > 0.45 and (hh < 0.06 or hh > 0.9)
            if inside(x, y, P_TUSKS) or (brute and 42 <= x < 52 and y < 6 and s < 0.3):
                m = "tusk"
            elif inside(x, y, P_SNOUT):
                m = "nostril" if L < 0.25 else "snout"
            elif (x, y) in P_EYES:
                m = "socket" if zombie else "eye"
            elif 0.06 < hh < 0.17 and s > 0.4 and L > 0.38:
                m = "gold"
            elif brute and 0.7 < hh < 0.8:
                m = "stud"
            elif zombie and c in P_BONE:
                m = "bone"
            elif c in P_STRAP:
                m = "strap"
            elif brute and (hh > 0.9 or hh < 0.06) and s > 0.35 and L < 0.27:
                # Maroon: the brute's own skin on its head, leather below.
                m = "skin" if inside(x, y, P_HEAD) else "leather"
            elif not red and L < 0.5 and s < 0.3:
                m = "hood" if brute else "leather"
            else:
                m = "skin"
            mat[y, x] = m
        skin = ROT if zombie else PIG_SKIN
        top = skin["base"]
        mats = {"skin": skin, "snout": SNOUT, "nostril": NOSTRIL, "tusk": TUSK, "gold": GOLD,
                "eye": PIG_EYE, "socket": pit(top - 0.5), "bone": BARE, "strap": STRAP,
                "leather": LEATHER, "hood": PIG_HOOD, "stud": PIG_STUD}
        # The brute's dark art spans more of the range; at the cow's 24 its
        # relief measured 0.107 node, over the client's 0.10 cap.
        out[stem] = spec_of(mat, mats, src, "cloth", {"strength": 21.0} if brute else None)
    return out


# --- hoglin and zoglin --------------------------------------------------------------
# extra_mobs_hoglin.b3d, brush 0: a long head, the snout's front at
# (80, 20)..(94, 26), the tusks boxes at the left, the mane two crossed
# planes along the back.

H_TUSKS = [(1, 13, 19, 26)]
H_MANE = [(90, 48, 128, 62)]
H_FRONT = (80, 1, 94, 20)
H_HOOF = {"#77301a", "#91371c"}

HOG_FUR = {"mode": "shade", "base": 0.8, "span": 0.12, "levels": 3, "detail": 0.25,
           "joints": False, "smooth": 0.18, "smooth_spread": 0.03, "micro": "fur",
           "micro_params": {"length": 1.2, "clump": 0.45}, "micro_strength": 0.45,
           "micro_swing": 0.4}
# The mane and the strider's hair are crossed planes of sparse strands, not
# boxes: lock_round's roll and the edge roll found no level at a strand's
# middle, so they take plain locks by shade with the crisp chamfer.
HAIR = {k: v for k, v in mf.MANE.items() if k not in ("lock_round", "edge_roll", "edge_lean",
                                                      "roll_rough")}
HOG_MANE = dict(HAIR, base=0.84)
HOG_HOOF = {"mode": "flat", "base": 0.92, "span": 0.0, "micro": "bone", "smooth": 0.45,
            "smooth_spread": 0.0, "micro_strength": 0.3, "micro_params": {"cracks": 0.8}}
HOG_EYE = eye(0.86)
# At the cow's keys the relief measured 0.109 node, over the cap, and the
# fur's tufts leaned some face border pixels inward past the bevel.
HOG_KEYS = {"strength": 21.0, "bevel_depth": 0.1}
# The snout's front is 14 x 6 texels seen nearly edge on from 60 degrees:
# with the piglin's snout at 0.96 and nostrils at 0.66 it kept 81% of its
# texels, so here the snout stands at the fur's top and the nostrils are
# shallow.
HOG_SNOUT = dict(SNOUT, base=0.92)
HOG_NOSTRIL = pit(0.86, smooth=0.55)
ZOG_ROT = dict(ROT, base=0.88)
ZOG_SNOUT = dict(HOG_SNOUT, micro="rotten", micro_strength=0.5, micro_params={}, smooth=0.4)


def hoglin_specs():
    out = {}
    live = load("extra_mobs_hoglin")
    snout = np.zeros(live.shape[:2], bool)
    nostril = np.zeros(live.shape[:2], bool)
    for x, y, rgb, hh, s, v, L in texels(live):
        if (hh < 0.03 or hh > 0.95) and 0.45 < s < 0.65 and L > 0.3 and y >= 17:
            snout[y, x] = True
        elif (hh < 0.03 or hh > 0.95) and s > 0.7 and 20 <= y < 26 and 78 <= x < 96:
            nostril[y, x] = True
    for stem in ("extra_mobs_hoglin", "extra_mobs_zoglin"):
        src = load(stem)
        hx = hexes(src)
        h, w = src.shape[:2]
        zombie = stem.endswith("zoglin")
        mat = np.full((h, w), "fur", dtype=object)
        x0, y0, x1, y1 = H_FRONT
        for x, y, rgb, hh, s, v, L in texels(src):
            c = hx[y, x]
            cream = s < 0.3 and L > 0.4 and 0.04 < hh < 0.17
            if inside(x, y, H_MANE):
                m = "mane"
            elif inside(x, y, H_TUSKS):
                m = "tusk" if L > 0.4 else "fur"
            elif 0.07 < hh < 0.17 and s > 0.4 and L > 0.38:
                m = "gold"
            elif nostril[y, x]:
                m = "nostril"
            elif snout[y, x]:
                m = "snout"
            elif c in H_HOOF:
                m = "hoof"
            elif x0 <= x < x1 and 8 <= y < 12 and (s > 0.7 or c == "#2d2522"):
                m = "socket" if zombie else "eye"
            elif zombie and cream:
                m = "bone"
            elif zombie and 0.13 < hh < 0.45 and s > 0.14:
                m = "rot"
            else:
                m = "fur"
            mat[y, x] = m
        mats = {"fur": HOG_FUR, "mane": HOG_MANE, "tusk": TUSK, "gold": GOLD,
                "snout": ZOG_SNOUT if zombie else HOG_SNOUT, "nostril": HOG_NOSTRIL, "hoof": HOG_HOOF,
                "eye": HOG_EYE, "socket": pit(0.42), "bone": BARE, "rot": ZOG_ROT}
        out[stem] = spec_of(mat, mats, src, "cloth", HOG_KEYS)
    return out


# --- striders --------------------------------------------------------------------------
# extra_mobs_strider.b3d, brush 0 (1 is the saddle, the pig's art). The body
# is one 16 x 14 x 16 box, the legs below it, the hair three planes.

S_BODY = [(0, 0, 64, 30)]
S_LEGS = [(0, 32, 16, 76)]
S_HAIR = [(32, 33, 48, 81)]
S_FRONT = (16, 16, 32, 30)

# The roll leans 15 degrees, not the face rules' 10: at 10 the hide's
# wrinkles turned 7% of the body's border pixels inward.
STR_SKIN = dict(SKIN, base=0.9, micro_params={"cell": 0.7, "wrinkles": 0.8}, micro_strength=0.6,
                edge_lean=15)
STR_LEG = {"mode": "shade", "base": 0.8, "span": 0.12, "levels": 3, "detail": 0.25,
           "joints": False, "smooth": 0.3, "smooth_spread": 0.03, "micro": "hide",
           "micro_params": {"cell": 0.6, "wrinkles": 1.4}, "micro_strength": 0.6,
           "scatter": 0.2}
# Flat: by shade, a hair plane seen at 35 degrees kept 86% of its texels.
STR_HAIR = dict(HAIR, base=0.86, mode="flat", span=0.0)
# The body's dark markings: lines sunk into the skin like scars.
STR_MARK = {"mode": "flat", "base": 0.76, "span": 0.0, "micro": "hide", "smooth": 0.26,
            "smooth_spread": 0.0, "micro_params": {"cell": 0.5}, "micro_strength": 0.4}


def strider_specs():
    out = {}
    for stem in ("extra_mobs_strider", "extra_mobs_strider_cold"):
        src = load(stem)
        hx = hexes(src)
        h, w = src.shape[:2]
        mat = np.full((h, w), "skin", dtype=object)
        fx0, fy0, fx1, fy1 = S_FRONT
        for x, y, rgb, hh, s, v, L in texels(src):
            c = hx[y, x]
            if inside(x, y, S_HAIR):
                m = "hair"
            elif inside(x, y, S_LEGS):
                m = "leg"
            elif c == "#fbf5c6":
                m = "sclera"
            elif c == "#e4a57b":
                m = "iris"
            elif s < 0.05 and fx0 <= x < fx1 and y >= 25:
                m = "mouth"
            elif s < 0.05:
                m = "mark"
            else:
                m = "skin"
            mat[y, x] = m
        top = STR_SKIN["base"]
        mats = {"skin": STR_SKIN, "leg": STR_LEG, "hair": STR_HAIR, "mark": STR_MARK,
                "mouth": pit(0.6, smooth=0.4), "sclera": eye(top, 0.6), "iris": eye(top)}
        out[stem] = spec_of(mat, mats, src, "cloth")
    return out


# --- blaze --------------------------------------------------------------------------------
# mobs_mc_blaze.b3d, no brush: an 8 px head and twelve rods drawn from one
# 2 x 8 x 2 rod at (0, 16). The rods burn: they glow by shade band.

B_RODS = [(0, 16, 8, 26)]
BLAZE_HEAD = {"mode": "shade", "base": 0.8, "span": 0.14, "levels": 3, "detail": 0.3,
              "joints": False, "smooth": 0.22, "smooth_spread": 0.03, "micro": "mottle",
              "micro_params": {"cell": 0.5}, "micro_strength": 0.4, "micro_swing": 0.3}
BLAZE_ROD_END = {"mode": "flat", "base": 0.84, "span": 0.0, "micro": "rust", "micro_strength": 0.5,
                 "smooth": 0.2, "smooth_spread": 0.0}


def blaze_specs():
    src = load("mobs_mc_blaze")
    hx = hexes(src)
    h, w = src.shape[:2]
    mat = np.full((h, w), "head", dtype=object)
    band = {"#ff7200": "rod_hot", "#d34f1f": "rod_warm", "#bc2500": "rod", "#892000": "rod_dim"}
    for x, y, rgb, hh, s, v, L in texels(src):
        c = hx[y, x]
        if c in band:
            m = band[c]
        elif inside(x, y, B_RODS):
            m = "rod_end"
        elif 0.45 < hh < 0.6 and s > 0.3:
            m = "eye"
        else:
            m = "head"
        mat[y, x] = m
    # The bands step 0.04: a rod is two texels wide, and at 0.08 steps one
    # seen from 60 degrees kept 88% of its texels.
    mats = {"head": BLAZE_HEAD, "eye": eye(0.87), "rod_end": BLAZE_ROD_END,
            "rod_hot": glow(0.96, 1.0), "rod_warm": glow(0.92, 0.8), "rod": glow(0.88, 0.6),
            "rod_dim": glow(0.84, 0.4)}
    return {"mobs_mc_blaze": spec_of(mat, mats, src, "stone")}


# --- ghast -----------------------------------------------------------------------------------
# mobs_mc_ghast.b3d, no brush: a 16 px cube and nine tentacles drawn from
# one 2 x 14 x 2 at (0, 0). Its face is (16, 16)..(32, 32); the dark square
# at (32, 0) is the underside the tentacles hang from. ghast_firing is the
# same skin with the eyes open and the mouth burning, swapped in by
# set_textures while it shoots.

G_UNDER = [(32, 0, 48, 16)]
G_FACE = (16, 16, 32, 32)
GHAST_SKIN = dict(SKIN, base=0.9, micro="none", micro_params={}, smooth=0.3,
                  scatter=0.4, round=3)
GHAST_UNDER = {"mode": "flat", "base": 0.84, "span": 0.0, "micro": "skin", "micro_strength": 0.3,
               "smooth": 0.22, "smooth_spread": 0.0, "scatter": 0.2}
# Closed eyes and the shut mouth: creases a little under the skin.
GHAST_CREASE = pit(0.74, smooth=0.3)


def ghast_specs():
    out = {}
    for stem in ("mobs_mc_ghast", "mobs_mc_ghast_firing"):
        src = load(stem)
        h, w = src.shape[:2]
        mat = np.full((h, w), "skin", dtype=object)
        x0, y0, x1, y1 = G_FACE
        for x, y, rgb, hh, s, v, L in texels(src):
            if inside(x, y, G_UNDER):
                m = "under"
            elif x0 <= x < x1 and y0 <= y < y1 and L < 0.5:
                mouth = y >= 25
                if stem.endswith("firing"):
                    if s > 0.5:
                        m = "mouth_glow" if mouth else "eye_glow"
                    else:
                        m = "mouth" if mouth else "eye"
                else:
                    m = "crease"
            else:
                m = "skin"
            mat[y, x] = m
        top = GHAST_SKIN["base"]
        mats = {"skin": GHAST_SKIN, "under": GHAST_UNDER, "crease": GHAST_CREASE,
                "eye": eye(top), "eye_glow": eye(top, emission=0.9),
                "mouth": pit(0.5), "mouth_glow": pit(0.5, smooth=0.5, emission=1.0)}
        out[stem] = spec_of(mat, mats, src, "cloth")
    return out


# --- magma cube ------------------------------------------------------------------------------
# mobs_mc_magmacube.b3d, brush 0: the shell in eight slices round a core
# box at (12, 32)..(48, 56). The core burns by shade band; the shell is a
# dark crust.

MAGMA_CRUST = {"mode": "shade", "base": 0.8, "span": 0.14, "levels": 3, "detail": 0.3,
               "joints": False, "smooth": 0.24, "smooth_spread": 0.03, "micro": "rust",
               "micro_strength": 0.5}


def magma_specs():
    src = load("mobs_mc_magmacube")
    hx = hexes(src)
    h, w = src.shape[:2]
    mat = np.full((h, w), "crust", dtype=object)
    band = {"#ee6014": "core_hot", "#c6452c": "core", "#ac1b0b": "core_dim"}
    for x, y, rgb, hh, s, v, L in texels(src):
        mat[y, x] = band.get(hx[y, x], "crust")
    mats = {"crust": MAGMA_CRUST, "core_hot": glow(0.96, 1.0, smooth=0.6),
            "core": glow(0.88, 0.7, smooth=0.6), "core_dim": glow(0.8, 0.45, smooth=0.6)}
    return {"mobs_mc_magmacube": spec_of(mat, mats, src, "stone")}


# --- ender dragon ---------------------------------------------------------------------------
# mobs_mc_dragon.b3d, no brush, a 256 px atlas: 8 map pixels to the texel
# (2048 square), not 16, which would be 4096. The wings' membranes are
# (0, 88)..(112, 200); the purple grey is the spine, the belly and head
# plates, and inside the wings the bones; the magenta in rows 47 to 51 its
# eyes, which glow. The magenta below them on the snout is a plate.

D_WINGS = [(0, 88, 112, 200)]
DRAGON_SCALE = {"mode": "shade", "base": 0.8, "span": 0.1, "levels": 3, "detail": 0.25,
                "joints": False, "smooth": 0.2, "smooth_spread": 0.03, "micro": "scale",
                "micro_params": {"length": 0.8, "width": 0.8}, "micro_strength": 0.7,
                "micro_swing": 0.4}
DRAGON_PLATE = {"mode": "shade", "base": 0.84, "span": 0.1, "levels": 3, "detail": 0.3,
                "joints": False, "smooth": 0.42, "smooth_spread": 0.03, "micro": "bone",
                "micro_strength": 1.0, "micro_params": {"cracks": 0.6}}
DRAGON_MEMBRANE = {"mode": "flat", "base": 0.84, "span": 0.0, "micro": "hide",
                   "micro_params": {"cell": 1.2, "wrinkles": 0.6}, "micro_strength": 0.5,
                   "smooth": 0.2, "smooth_spread": 0.0, "scatter": 0.3}
DRAGON_BONE = {"mode": "flat", "base": 0.94, "span": 0.0, "micro": "bone", "micro_strength": 0.8,
               "smooth": 0.42, "smooth_spread": 0.0}


def dragon_specs():
    src = load("mobs_mc_dragon")
    h, w = src.shape[:2]
    mat = np.full((h, w), "scale", dtype=object)
    for x, y, rgb, hh, s, v, L in texels(src):
        wing = inside(x, y, D_WINGS)
        if s > 0.5 and 0.78 < hh < 0.85 and 47 <= y < 52:
            m = "eye"
        elif 0.66 < hh < 0.76 and s > 0.25:
            m = "bone" if wing else "plate"
        elif wing and L > 0.3:
            m = "bone"
        elif wing:
            m = "membrane"
        else:
            m = "scale"
        mat[y, x] = m
    mats = {"scale": DRAGON_SCALE, "plate": DRAGON_PLATE, "membrane": DRAGON_MEMBRANE,
            "bone": DRAGON_BONE,
            # Shade led emission left the eyes at 0.2: their bright texels
            # are too few to set the material's range. One level instead.
            "eye": eye(0.88, emission=0.8)}
    return {"mobs_mc_dragon": spec_of(mat, mats, src, "cloth", {"texel_px": 8, "strength": 16.0})}


# --- wither -------------------------------------------------------------------------------
# mobs_mc_wither.b3d: brush 0 the skeleton (mobs_mc_wither, or
# mobs_mc_wither_invulnerable while it charges), brush 1 the armour shell
# drawn on slightly larger boxes once it is under half health. The heads'
# fronts are (8, 8)..(16, 16) and (38, 6)..(44, 12); (8, 44)..(16, 52) is
# a head layout the model does not use.

W_FRONTS = [(8, 8, 16, 16), (38, 6, 44, 12), (8, 44, 16, 52)]
# Flat bone, as the wither skeleton's, with the sockets 0.18 under it. By
# shade, and with the sockets half the range down, the side heads' six
# texel fronts and the spine's two texel faces kept 86 to 88% of their
# texels from 60 degrees: these faces are too small for both.
WITHER_BONE = {"mode": "flat", "base": 0.88, "span": 0.0, "micro": "bone", "micro_strength": 1.6,
               "micro_params": {"cracks": 0.9}, "smooth": 0.22, "smooth_spread": 0.0}
# The armour's blobs by shade, shallow, and at strength 12: at a span of
# 0.16 an arm face three texels wide kept 67% from 60 degrees.
WITHER_AURA = {"mode": "shade", "base": 0.8, "span": 0.1, "levels": 3, "detail": 0.3,
               "joints": False, "micro": "mottle", "micro_params": {"cell": 0.7},
               "micro_strength": 0.4, "micro_swing": 0.3, "smooth": 0.34, "smooth_spread": 0.04,
               "scatter": 0.2}


def wither_specs():
    out = {}
    base = load("mobs_mc_wither")
    h, w = base.shape[:2]
    holes = np.zeros((h, w), bool)
    for x, y, rgb, hh, s, v, L in texels(base):
        if inside(x, y, W_FRONTS) and (L > 0.5 or L < 0.06):
            holes[y, x] = True
    for stem in ("mobs_mc_wither", "mobs_mc_wither_invulnerable"):
        src = load(stem)
        mat = np.full((h, w), "bone", dtype=object)
        for x, y, rgb, hh, s, v, L in texels(src):
            if holes[y, x]:
                mat[y, x] = "eye" if L > 0.2 else "socket"
        mats = {"bone": WITHER_BONE, "socket": pit(0.7, smooth=0.15),
                "eye": pit(0.7, smooth=0.3)}
        out[stem] = spec_of(mat, mats, src, "stone")
    src = load("mobs_mc_wither_armor")
    mat = np.full((h, w), "aura", dtype=object)
    out["mobs_mc_wither_armor"] = spec_of(mat, {"aura": WITHER_AURA}, src, "cloth",
                                          {"overlay": True, "surface": 0.8, "strength": 12.0})
    return out


# --- endermite, silverfish -----------------------------------------------------------------

# The endermite is near black: glossier, or with stronger ridges, its back
# lost a third of its art contrast to the sky's reflection.
MITE_CHITIN = {"mode": "shade", "base": 0.82, "span": 0.1, "levels": 3, "detail": 0.25,
               "joints": False, "smooth": 0.3, "smooth_spread": 0.03, "micro": "chitin",
               "micro_strength": 0.2, "micro_swing": 0.3}
# At a span of 0.14 a leg face two texels wide kept 80% of its texels from
# 60 degrees.
FISH_CHITIN = dict(MITE_CHITIN, smooth=0.55, micro_strength=0.6)


def bug_specs():
    out = {}
    src = load("mobs_mc_endermite")
    h, w = src.shape[:2]
    mat = np.full((h, w), "chitin", dtype=object)
    for x, y, rgb, hh, s, v, L in texels(src):
        if s > 0.95 and (hh < 0.08):
            mat[y, x] = "mouth" if y == 0 else "eye"
    out["mobs_mc_endermite"] = spec_of(
        mat, {"chitin": MITE_CHITIN, "eye": eye(0.88), "mouth": pit(0.7, smooth=0.5)}, src, "cloth",
        {"strength": 20.0})
    src = load("mobs_mc_silverfish")
    hx = hexes(src)
    h, w = src.shape[:2]
    mat = np.full((h, w), "chitin", dtype=object)
    for x, y, rgb, hh, s, v, L in texels(src):
        if hx[y, x] == "#472424":
            mat[y, x] = "eye"
    out["mobs_mc_silverfish"] = spec_of(mat, {"chitin": FISH_CHITIN, "eye": eye(0.89)}, src,
                                        "cloth")
    return out


# --- guardians -------------------------------------------------------------------------------
# mobs_mc_guardian.b3d, no brush. The spikes are twelve boxes drawn from
# (0, 0)..(8, 11), the pupil a small box at (8, 0)..(14, 3) in front of the
# eye painted on the head's front at (19, 21)..(25, 24). The guardian's
# eye white glows, the elder's pupil.

GU_SPIKES = [(0, 0, 8, 11)]
GU_PUPIL = [(8, 0, 14, 3)]
GU_EYE = [(19, 21, 25, 24)]
# A span of 0.1: at 0.14 the tail's six by two texel faces kept 83%.
GUARD_SCALE = {"mode": "shade", "base": 0.8, "span": 0.1, "levels": 3, "detail": 0.25,
               "joints": False, "smooth": 0.45, "smooth_spread": 0.03, "micro": "scale",
               "micro_params": {"length": 0.7, "width": 0.7}, "micro_strength": 0.7,
               "micro_swing": 0.4, "scatter": 0.1}
GUARD_SPIKE = {"mode": "flat", "base": 0.96, "span": 0.0, "micro": "bone", "micro_strength": 0.6,
               "micro_params": {"cracks": 0.4}, "smooth": 0.55, "smooth_spread": 0.0}
GUARD_FIN = {"mode": "flat", "base": 0.9, "span": 0.0, "micro": "hide",
             "micro_params": {"cell": 0.5, "wrinkles": 1.6}, "micro_strength": 0.4,
             "smooth": 0.5, "smooth_spread": 0.0, "scatter": 0.3}


def guardian_specs():
    out = {}
    for stem in ("mobs_mc_guardian", "mobs_mc_guardian_elder"):
        src = load(stem)
        h, w = src.shape[:2]
        elder = stem.endswith("elder")
        mat = np.full((h, w), "scale", dtype=object)
        for x, y, rgb, hh, s, v, L in texels(src):
            if inside(x, y, GU_SPIKES):
                m = "spike"
            elif inside(x, y, GU_PUPIL):
                m = "pupil"
            elif inside(x, y, GU_EYE):
                m = "white"
            elif (not elder and hh < 0.1 and s > 0.35) or (elder and 0.55 < hh < 0.65 and s > 0.3):
                m = "fin"
            else:
                m = "scale"
            mat[y, x] = m
        top = 0.87
        if elder:
            pupil, white = eye(top, emission=0.8), eye(top, 0.6)
        else:
            pupil, white = eye(top), eye(top, 0.6, emission=0.7)
        mats = {"scale": GUARD_SCALE, "spike": GUARD_SPIKE, "fin": GUARD_FIN, "pupil": pupil,
                "white": white}
        # At the cow's 24 the relief measured 0.108 node, over the cap.
        out[stem] = spec_of(mat, mats, src, "cloth", {"strength": 21.0})
    return out


# --- shulkers ----------------------------------------------------------------------------------
# mobs_mc_shulker.b3d, brush 0: the lid (top and sides) and the base (its
# underside and sides) above row 52, the head below it. Every colour is the
# one layout, four shell shades, the darkest the outline of each plate.

SHELL = {"mode": "shade", "base": 0.84, "span": 0.14, "levels": 3, "detail": 0.3,
         "joints": False, "smooth": 0.42, "smooth_spread": 0.03, "micro": "bone",
         "micro_strength": 0.8, "micro_params": {"cracks": 0.4}, "wear": 0.08}
SEAM = {"mode": "flat", "base": 0.7, "span": 0.0, "micro": "bone", "micro_strength": 0.5,
        "smooth": 0.3, "smooth_spread": 0.0}
SHULKER_HEAD = dict(SKIN, base=0.9, micro="none", micro_params={},
                    smooth=0.25, scatter=0.4)


def shulker_specs():
    out = {}
    for stem in ["mobs_mc_endergolem"] + ["mobs_mc_shulker_" + c for c in SHULKER_COLOURS]:
        src = load(stem)
        hx = hexes(src)
        h, w = src.shape[:2]
        drawn = src[..., 3] >= 0.5
        shell = drawn.copy()
        shell[52:] = False
        lum = lib.luminance(src[..., :3])
        cols = sorted(set(hx[shell]), key=lambda c: float(lum[hx == c].mean()))
        seam = cols[0]
        mat = np.full((h, w), "shell", dtype=object)
        for x, y, rgb, hh, s, v, L in texels(src):
            if y < 52:
                m = "seam" if hx[y, x] == seam else "shell"
            elif hx[y, x] == "#5b4346":
                m = "eye"
            else:
                m = "head"
            mat[y, x] = m
        mats = {"shell": SHELL, "seam": SEAM, "head": SHULKER_HEAD,
                "eye": eye(SHULKER_HEAD["base"])}
        # The lid's sides are cut into teeth with transparent gaps. Built as
        # an overlay, as the llama's carpets are, the gaps stand at the
        # shell's top, so the teeth do not chamfer down into them: they did,
        # and drew a bright line round every tooth.
        out[stem] = spec_of(mat, mats, src, "stone", {"overlay": True, "surface": 0.9})
    return out


# The face studies the default build ignores (README, "Sculpted faces" and
# "Crisp sculpted faces"): GOANNA_PBR_VARIANT=<name> lays one over the spec.
# They were first written into the specs by hand, so a regeneration dropped
# them; they live here now and are written as each spec's last key.
VARIANTS = {
    "extra_mobs_piglin": {
        "sculpt": {"materials": {"skin": {"span": 0.22}, "eye": {"flush": {"to": ["skin"]}}}},
        "sculpt_crisp": {
            "strength": 22,
            "rects": [["earhole", 40, 11, 42, 13], ["earhole", 57, 11, 59, 13]],
            "materials": {
                "skin": {
                    "mode": "shade",
                    "base": 0.818,
                    "span": 0.164,
                    "levels": 3,
                    "detail": 0.25,
                    "merge": 0.2,
                    "joints": False,
                    "soft_edge": None,
                    "ride": True,
                    "round": 3,
                    "edge_roll": 2,
                    "edge_lean": 10,
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
                    "flush": {"to": ["skin"], "group": "eye"},
                    "ride": True,
                    "round": 3,
                    "edge_roll": 2,
                    "edge_lean": 10,
                    "roll_rough": 0.03,
                    "scatter": 0,
                },
                "earhole": {
                    "mode": "flat",
                    "base": 0.775,
                    "span": 0.0,
                    "micro": "none",
                    "smooth": 0.3,
                    "smooth_spread": 0.0,
                    "scatter": 0.3,
                    "ride": True,
                    "round": 3,
                    "edge_roll": 2,
                    "edge_lean": 10,
                    "roll_rough": 0.03,
                },
            },
        },
    },
}


FAMILIES = {"piglin": piglin_specs, "hoglin": hoglin_specs, "strider": strider_specs,
            "blaze": blaze_specs, "ghast": ghast_specs, "magma": magma_specs,
            "dragon": dragon_specs, "wither": wither_specs, "bugs": bug_specs,
            "guardian": guardian_specs, "shulker": shulker_specs}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check_only = "--check" in sys.argv
    stale = []
    for name in args or list(FAMILIES):
        for stem, spec in FAMILIES[name]().items():
            if stem in VARIANTS:
                spec = {**spec, "variants": VARIANTS[stem]}
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
