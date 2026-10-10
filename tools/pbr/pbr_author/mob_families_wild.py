"""Specs for the wild and water mob skins, written from part maps.

The same approach as mob_families.py, which this reuses: a part name per
art texel from the model's own face rectangles (atlas.faces, listed per
family below), a few rules per family that read the stem's own art (eyes,
noses, mouths, glowing spots), and one material table per family. Coats of
one family (eight rabbits, five parrots, seven axolotls, the tropical
fish's bodies and their twelve patterns) share the table, so the coat is
one decision judged once.

    python3 tools/pbr/pbr_author/mob_families_wild.py            # write every spec
    python3 tools/pbr/pbr_author/mob_families_wild.py --check    # exit 1 if any differs
    python3 tools/pbr/pbr_author/mob_families_wild.py rabbit     # one family

Eyes follow the rule accepted on 2026-10-03: flat and flush with the face,
the iris (and a pupil) at smoothness 0.8, a drawn white of the eye at 0.6,
no F0 boost. Wet animals take a sheen in the smoothness that keeps the
art's contrast; fish scales are a light finish.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import atlas  # noqa: E402
import lib  # noqa: E402
import mob_families as mf  # noqa: E402
from mob_families import hsv, lum, paint, to_spec, write  # noqa: E402

GAME = "mineclonia"

# --- shared materials -----------------------------------------------------------
# The approved coat, muzzle, nose and ear materials come from mob_families.py
# so that a cow's fur and a rabbit's fur stay one decision.


def eye(base, smooth=0.8):
    """An eye texel: flat, flush with the face around it, no micro, no F0."""
    return {"mode": "flat", "base": base, "span": 0.0, "micro": "none", "smooth": smooth,
            "smooth_spread": 0.0}


def sclera(base):
    return eye(base, 0.6)


def wet(base, smooth, span=0.08, micro_strength=0.2, cell=0.5, scatter=0.3, rnd=8,
        roll=1.5):
    """Wet skin: soft (lighter a little higher, rounded steps, a dome, a rolled
    box edge), its sheen in the smoothness, a faint crease net."""
    return {"mode": "soft", "base": base, "span": span, "detail": 0.25, "soft_edge": 0.4,
            "round": rnd, "edge_roll": roll, "edge_lean": 15, "roll_rough": 0.05,
            "smooth": smooth, "smooth_spread": 0.02, "micro": "hide",
            "micro_params": {"cell": cell, "wrinkles": 0.4}, "micro_strength": micro_strength,
            "scatter": scatter}


def scales(base, smooth, strength=0.25, levels=2, span=0.1):
    """Fish scales: by shade, shallow, the scale kind as a light finish."""
    return {"mode": "shade", "base": base, "span": span, "levels": levels, "detail": 0.3,
            "joints": False, "smooth": smooth, "smooth_spread": 0.02, "micro": "scale",
            "micro_strength": strength, "micro_params": {"length": 0.6, "width": 0.6}}


def fin(base, smooth):
    """A fin or fluke: thin, soft, wet, a faint crease."""
    return {"mode": "soft", "base": base, "span": 0.06, "detail": 0.25, "soft_edge": 0.4,
            "round": 4, "edge_roll": 1, "edge_lean": 20, "roll_rough": 0.05, "smooth": smooth,
            "smooth_spread": 0.02, "micro": "hide", "micro_params": {"cell": 0.35, "wrinkles": 1.6},
            "micro_strength": 0.15, "scatter": 0.5}


# Skins with cut-out planes or faces whose art leaves holes (fins, wings,
# gills, the mushrooms, the parrot's crest) are built with "overlay": true,
# as the llama's carpets are: the transparent texels stand at the surface's
# height, so a silhouette does not chamfer down to zero into texels the
# game never draws, which put a steep rim on every cut edge and failed the
# border lean check there.
CUTOUT = {"overlay": True, "surface": 0.9}


def in_rects(x, y, rects):
    return any(x0 <= x < x1 and y0 <= y < y1 for x0, y0, x1, y1 in rects)


def face_rects(model, brush, w, h):
    return [r for r, _ in atlas.faces(model, brush, w, h, GAME)]


def drawn_texels(src):
    return zip(*np.nonzero(src[..., 3] >= 0.5))


# --- rabbits --------------------------------------------------------------------
# mobs_mc_rabbit.b3d, brush 0, 64 x 32. Toast and the killer rabbit
# (caerbannog) are the same layout.

R_NOSEBOX = [(32, 9, 36, 11)]
R_EARS = [(52, 0, 64, 6)]
R_TAIL = [(52, 6, 62, 11)]
R_EYES = [(38, 6), (40, 6)]
RABBITS = ["mobs_mc_rabbit_" + c for c in ("brown", "gold", "white", "white_splotched", "salt",
                                           "black", "toast", "caerbannog")]
# The tail is a cotton ball: the llama's soft fleece, a touch prouder.
R_TAIL_M = dict(mf.FLEECE, base=0.88, round=6, edge_roll=1.5)
R_EAR_INNER = {"mode": "flat", "base": 0.82, "span": 0.0, "micro": "hide", "smooth": 0.4,
               "smooth_spread": 0.0, "micro_params": {"cell": 0.35}, "micro_strength": 0.2,
               "scatter": 0.5}
RABBIT_MATERIALS = {"fur": mf.PET_FUR, "nose": mf.NOSE, "eye": eye(0.82), "ear": mf.EAR,
                    "ear_inner": R_EAR_INNER, "tail": R_TAIL_M}


def pinkish(rgb):
    hh, s, v = hsv(rgb)
    return (hh > 0.85 or hh < 0.02) and s > 0.12 and v > 0.6


def rabbit_specs():
    out = {}
    w, h = 64, 32
    for stem in RABBITS:
        src = lib.load_source(stem, GAME)
        mat = np.full((h, w), "fur", dtype=object)
        for y, x in drawn_texels(src):
            rgb = src[y, x, :3]
            if in_rects(x, y, R_EARS):
                mat[y, x] = "ear_inner" if pinkish(rgb) else "ear"
            elif in_rects(x, y, R_TAIL):
                mat[y, x] = "tail"
            elif in_rects(x, y, R_NOSEBOX) and pinkish(rgb):
                mat[y, x] = "nose"
        for x, y in R_EYES:
            mat[y, x] = "eye"
        out[stem] = to_spec(mat, RABBIT_MATERIALS, src=src)
    return out


# --- parrots --------------------------------------------------------------------
# mobs_mc_parrot.b3d, brush -1, 32 x 32. The head (2..10, 2..7), the crest
# box above it and the crest plane, two beak boxes, the body, the wings,
# the tail and the legs.

P_HEAD = [(2, 2, 10, 7)]
# The eyes: one dark texel at the front corner of each side of the head.
P_EYES = [(3, 4), (6, 4)]
P_CREST = [(10, 0, 22, 5), (2, 22, 10, 27)]
P_BEAK = [(11, 7, 15, 10), (16, 7, 20, 10)]
P_WINGS = [(19, 8, 27, 16)]
P_TAIL = [(22, 1, 30, 6)]
P_LEGS = [(14, 18, 18, 21)]
PARROTS = ["mobs_mc_parrot_" + c for c in ("blue", "green", "grey", "red_blue", "yellow_blue")]
# The chicken's approved soft feathers (after its fix), the wings and tail
# with longer feathers, the head finer.
FEATHER = {"mode": "soft", "base": 0.88, "span": 0.08, "detail": 0.25, "soft_edge": 0.4, "round": 1,
           "edge_roll": 1, "edge_lean": 15, "roll_rough": 0.05, "smooth": 0.22,
           "smooth_spread": 0.02, "micro": "feather", "micro_strength": 0.4,
           "micro_params": {"length": 1.4, "width": 1.0, "barbs": 2.0}}
P_HEAD_M = dict(FEATHER, base=0.89, span=0.06, micro_strength=0.35,
                micro_params={"length": 0.9, "width": 0.7, "barbs": 2.0})
P_WING = dict(FEATHER, micro_strength=0.45, micro_params={"length": 2.0, "width": 1.0,
                                                          "barbs": 2.0})
# A parrot's beak is hard keratin, proud and smooth like the cow's muzzle.
P_BEAK_M = {"mode": "soft", "base": 0.99, "span": 0.02, "detail": 0.25, "soft_edge": 0.3,
            "round": 4, "edge_roll": 1, "edge_lean": 15, "roll_rough": 0.05, "smooth": 0.5,
            "smooth_spread": 0.0, "micro": "bone", "micro_strength": 0.15,
            "micro_params": {"cracks": 0.1}}
# The legs are one texel thin sticks: scaly, rolled at the box edge.
P_LEG = {"mode": "soft", "base": 0.86, "span": 0.06, "detail": 0.25, "soft_edge": 0.3, "round": 2,
         "edge_roll": 1, "edge_lean": 15, "roll_rough": 0.05, "smooth": 0.45,
         "smooth_spread": 0.0, "micro": "scale", "micro_strength": 0.3,
         "micro_params": {"length": 0.5, "width": 0.6}}
# The eyes sit on the corner texel of each head side, so they ride the
# head's roll: flat at their own height, curving with the box edge.
P_EYE = dict(eye(0.89), ride=True, edge_roll=1, edge_lean=22, roll_rough=0.03)
# A parrot's boxes are a few texels across, so the chicken's roll of 15
# degrees lost to the soft steps between shades at many border pixels;
# the roll leans a little further here.
PARROT_MATERIALS = {k: dict(m, edge_lean=22) if m.get("mode") == "soft" else m for k, m in {
    "feather": FEATHER, "head": P_HEAD_M, "crest": P_HEAD_M, "wing": P_WING, "tail": P_WING,
    "beak": P_BEAK_M, "eye": P_EYE, "leg": P_LEG}.items()}


def parrot_specs():
    out = {}
    w, h = 32, 32
    for stem in PARROTS:
        src = lib.load_source(stem, GAME)
        mat = np.full((h, w), "feather", dtype=object)
        for y, x in drawn_texels(src):
            if in_rects(x, y, P_HEAD):
                mat[y, x] = "eye" if (x, y) in P_EYES else "head"
            elif in_rects(x, y, P_CREST):
                mat[y, x] = "crest"
            elif in_rects(x, y, P_BEAK):
                mat[y, x] = "beak"
            elif in_rects(x, y, P_WINGS):
                mat[y, x] = "wing"
            elif in_rects(x, y, P_TAIL):
                mat[y, x] = "tail"
            elif in_rects(x, y, P_LEGS):
                mat[y, x] = "leg"
        out[stem] = to_spec(mat, PARROT_MATERIALS, dict(CUTOUT, surface=0.88), src)
    return out


# --- polar bear -----------------------------------------------------------------
# mobs_mc_polarbear.b3d, brush -1, 128 x 64.

B_HEAD_FRONT = [(7, 7, 14, 14)]
B_SNOUT = [(0, 44, 16, 50)]
B_EARS = [(26, 0, 32, 3)]
B_LEGS = [(50, 22, 74, 56)]
B_SOLES = [(62, 22, 66, 30), (60, 40, 64, 46)]
# The polar bear's long white coat: the wolf's ruff, prouder than a cow's.
B_FUR = dict(mf.LONG_FUR, base=0.78, span=0.1)
# A bear's snout is short fur, proud of the face.
B_SNOUT_M = dict(mf.SNOUT, base=0.9, span=0.08)
B_CLAW = {"mode": "flat", "base": 0.86, "span": 0.0, "micro": "bone", "smooth": 0.5,
          "smooth_spread": 0.0, "micro_strength": 0.3, "micro_params": {"cracks": 0.3}}
BEAR_MATERIALS = {"fur": B_FUR, "snout": B_SNOUT_M, "nose": mf.NOSE, "eye": eye(0.84),
                  "ear": mf.EAR, "pad": mf.PAD, "claw": B_CLAW}


def polarbear_specs():
    stem = "mobs_mc_polarbear"
    src = lib.load_source(stem, GAME)
    h, w = src.shape[:2]
    mat = np.full((h, w), "fur", dtype=object)
    for y, x in drawn_texels(src):
        rgb = src[y, x, :3]
        L = lum(rgb)
        if in_rects(x, y, B_HEAD_FRONT) and L < 0.35:
            mat[y, x] = "eye" if y <= 10 else "nose"
        elif in_rects(x, y, B_SNOUT):
            mat[y, x] = "nose" if L < 0.35 else "snout"
        elif in_rects(x, y, B_EARS):
            mat[y, x] = "ear"
        elif in_rects(x, y, B_LEGS):
            if L < 0.25:
                mat[y, x] = "claw"
            elif in_rects(x, y, B_SOLES) and L < 0.62:
                mat[y, x] = "pad"
    return {stem: to_spec(mat, BEAR_MATERIALS, src=src)}


# --- bat ------------------------------------------------------------------------
# mobs_mc_bat.b3d, brush 0, 32 x 32. The wing planes' art reaches past the
# rectangles the model draws; those texels are islands of their own.

T_HEAD = [(0, 7, 12, 12)]
T_BODY = [(0, 0, 10, 7)]
T_EARS = [(0, 13, 12, 21)]
# A bat's coat: the cow's, short and matte, its dark shades kept apart.
T_FUR = dict(mf.FUR, base=0.76, span=0.12)
# The wings: a thin leathery membrane, a little waxy, the veins the art
# draws darker and so a little lower, no joints.
T_WING = {"mode": "shade", "base": 0.82, "span": 0.1, "levels": 2, "detail": 0.3, "joints": False,
          "smooth": 0.36, "smooth_spread": 0.02, "micro": "hide",
          "micro_params": {"cell": 0.45, "wrinkles": 1.0}, "micro_strength": 0.25, "scatter": 0.5}
BAT_MATERIALS = {"wing": T_WING, "fur": T_FUR, "ear": mf.EAR, "ear_inner": R_EAR_INNER,
                 "nose": mf.NOSE, "eye": eye(0.84)}


def bat_specs():
    stem = "mobs_mc_bat"
    src = lib.load_source(stem, GAME)
    h, w = src.shape[:2]
    mat = np.full((h, w), "wing", dtype=object)
    for y, x in drawn_texels(src):
        rgb = src[y, x, :3]
        hh, s, v = hsv(rgb)
        if in_rects(x, y, T_HEAD):
            if 0.04 < hh < 0.14 and s > 0.5:
                mat[y, x] = "eye"
            elif pinkish(rgb) or (s > 0.3 and v > 0.4):
                mat[y, x] = "nose"
            else:
                mat[y, x] = "fur"
        elif in_rects(x, y, T_BODY):
            mat[y, x] = "fur"
        elif in_rects(x, y, T_EARS):
            mat[y, x] = "ear_inner" if s > 0.3 and v > 0.4 else "ear"
    return {stem: to_spec(mat, BAT_MATERIALS, dict(CUTOUT, surface=0.86), src)}


# --- slime ----------------------------------------------------------------------
# mobs_mc_slime.b3d: mesh 1 the translucent outer shell (0..64, 0..32, the
# art at alpha 194), mesh 0 the inner core (0..48, 32..56), two eye boxes
# and a mouth box. Both meshes are brush 0 and draw the same image.

S_SHELL = [(0, 0, 64, 32)]
S_EYES = [(3, 5, 7, 9), (9, 5, 13, 9)]
S_MOUTH = [(7, 10, 9, 12)]
# Jelly: as smooth as the maps allow without a mirror, scattering, no
# micro, lighter a touch higher with rounded steps and a domed face.
S_JELLY = {"mode": "soft", "base": 0.92, "span": 0.06, "detail": 0.25, "soft_edge": 0.5,
           "round": 10, "edge_roll": 2.5, "edge_lean": 20, "roll_rough": 0.03, "smooth": 0.78,
           "smooth_spread": 0.02, "micro": "none", "scatter": 1.0}
# The core: softer, less glossy, inside.
S_CORE = dict(S_JELLY, base=0.9, span=0.08, smooth=0.6, round=8, scatter=0.9)
SLIME_MATERIALS = {"jelly": S_JELLY, "core": S_CORE, "eye": eye(0.92), "mouth": eye(0.92, 0.6)}


def slime_specs():
    stem = "mobs_mc_slime"
    src = lib.load_source(stem, GAME)
    h, w = src.shape[:2]
    mat = np.full((h, w), "core", dtype=object)
    paint(mat, S_SHELL, "jelly")
    paint(mat, S_EYES, "eye")
    paint(mat, S_MOUTH, "mouth")
    return {stem: to_spec(mat, SLIME_MATERIALS, src=src)}


# --- snow golem -----------------------------------------------------------------
# mobs_mc_snowman.b3d: mesh 0 draws mobs_mc_snowman.png (the snow body, the
# snow head seen when sheared, the stick arms); meshes 1 to 6 draw the
# pumpkin head from farming_pumpkin_*.png, block textures with their own
# block maps. Every mesh is brush 0 and mesh 1's face spans the whole
# image, so the spec lists mesh 0's faces alone, read from the model here.
# The preview draws the pumpkin meshes with this image; ignore the head.

G_ARMS = [(32, 0, 60, 4)]
# Packed snow: soft, as the llama's fleece is. A crisp chamfer per shade
# on its noise of near equal greys drew a crazing of lines, cracked plaster.
SNOW = {"mode": "soft", "base": 0.9, "span": 0.08, "detail": 0.25, "soft_edge": 0.4, "round": 4,
        "edge_roll": 1.5, "edge_lean": 15, "roll_rough": 0.03, "smooth": 0.28,
        "smooth_spread": 0.02, "micro": "mottle", "micro_params": {"cell": 0.45},
        "micro_strength": 0.2, "micro_swing": 0.3, "scatter": 0.6}
# Coal lumps for the eyes, mouth and buttons: proud, a little glossy.
COAL = {"mode": "flat", "base": 0.96, "span": 0.0, "micro": "none", "smooth": 0.42,
        "smooth_spread": 0.0, "scatter": 0}
# The arms are two texels thick: one height, so parallax keeps both shades
# (stepped, an arm's top kept half its texels at a 35 degree view).
STICK = {"mode": "flat", "base": 0.9, "span": 0.0, "smooth": 0.26, "smooth_spread": 0.0,
         "micro": "bark", "micro_strength": 0.6}
SNOWMAN_MATERIALS = {"snow": SNOW, "coal": COAL, "stick": STICK}


def snowman_specs():
    stem = "mobs_mc_snowman"
    src = lib.load_source(stem, GAME)
    h, w = src.shape[:2]
    faces = []
    for pos, uv, tris in atlas.read_b3d(atlas.model_path("mobs_mc_snowman.b3d", GAME))[:1]:
        for b, idx in tris:
            for t in idx:
                u, v = uv[t, 0] * w, uv[t, 1] * h
                r = [int(round(u.min())), int(round(v.min())), int(round(u.max())),
                     int(round(v.max()))]
                if r[2] > r[0] and r[3] > r[1] and r not in faces:
                    faces.append(r)
    faces.sort(key=lambda r: (r[1], r[0]))
    mat = np.full((h, w), "snow", dtype=object)
    for y, x in drawn_texels(src):
        if in_rects(x, y, G_ARMS):
            mat[y, x] = "stick"
        elif lum(src[y, x, :3]) < 0.3:
            mat[y, x] = "coal"
    return {stem: to_spec(mat, SNOWMAN_MATERIALS, {"faces": faces}, src)}


# --- the mooshrooms' mushrooms --------------------------------------------------
# mobs_mc_cow.b3d brush 1: crossed planes on the back, each drawing the
# whole 16 x 16 image, the mushroom in its lower half. Soft, not stepped:
# a cap is one rounded piece of flesh, satin on the red, matte on the brown.
CAP = {"mode": "soft", "base": 0.9, "span": 0.08, "detail": 0.25, "soft_edge": 0.4, "round": 8,
       "edge_roll": 1.5, "edge_lean": 15, "roll_rough": 0.03, "smooth": 0.34,
       "smooth_spread": 0.04, "micro": "hide", "micro_params": {"cell": 0.5},
       "micro_strength": 0.15, "scatter": 0.4}
CAP_BROWN = dict(CAP, smooth=0.2)


def mushroom_specs():
    out = {}
    for stem, cap in (("mobs_mc_mushroom_red", CAP), ("mobs_mc_mushroom_brown", CAP_BROWN)):
        src = lib.load_source(stem, GAME)
        h, w = src.shape[:2]
        out[stem] = to_spec(np.full((h, w), "cap", dtype=object), {"cap": cap}, CUTOUT, src)
    return out


# --- squids ---------------------------------------------------------------------
# mobs_mc_squid.b3d, brush -1, 64 x 32: the body box (0..48, 0..28), its
# underside with the mouth (24..36, 0..12), the eight tentacles sharing one
# rectangle set (48..56, 0..20). The glow squid draws its own art on it.

Q_MOUTH = [(24, 0, 36, 12)]
Q_TENTACLES = [(48, 0, 56, 20)]
Q_PUPILS = [(15, 17), (21, 17)]
# Wet skin. The squid's art is dark blue, and dark glossy art washed out on
# the spiders: at smoothness 0.5 the face with the eyes kept 76% of its art
# contrast under a low sun, at 0.3 it keeps 84%. The roll is narrow for the
# same reason.
Q_SKIN = wet(0.9, 0.3, rnd=4, roll=1.0)
Q_TENTACLE = wet(0.9, 0.3, span=0.05, rnd=4, roll=1)
Q_GUM = dict(mf.GUM, smooth=0.5)
Q_THROAT = dict(mf.THROAT, base=0.7)
# The glow squid's spots: the bright cyan texels glow, lighter brighter.
Q_GLOW = dict(wet(0.9, 0.5, span=0.05, rnd=4, roll=1), emission=0.8, emission_shade=True)
SQUID_MATERIALS = {"skin": Q_SKIN, "tentacle": Q_TENTACLE, "glow": Q_GLOW, "gum": Q_GUM,
                   "teeth": mf.TEETH, "throat": Q_THROAT, "eye": eye(0.92),
                   "sclera": sclera(0.92)}


def squid_specs():
    out = {}
    for stem in ("mobs_mc_squid", "extra_mobs_glow_squid"):
        src = lib.load_source(stem, GAME)
        h, w = src.shape[:2]
        mat = np.full((h, w), "skin", dtype=object)
        glow = stem.startswith("extra")
        for y, x in drawn_texels(src):
            rgb = src[y, x, :3]
            hh, s, v = hsv(rgb)
            L = lum(rgb)
            if in_rects(x, y, Q_MOUTH):
                # The beak ring: cream teeth, brown or peach lips, the dark
                # red throat, the dark skin around it.
                if L > 0.7:
                    mat[y, x] = "teeth"
                elif s > 0.4 and (hh < 0.12 or hh > 0.95):
                    mat[y, x] = "throat" if L < 0.12 else "gum"
                else:
                    mat[y, x] = "skin"
                continue
            tent = in_rects(x, y, Q_TENTACLES)
            if glow and L > 0.45 and s < 0.4:
                mat[y, x] = "glow"
            elif not glow and L > 0.7:
                mat[y, x] = "sclera"
            elif tent:
                mat[y, x] = "tentacle"
        if not glow:
            # The pupil at the inner corner of each white of the eye.
            for x, y in Q_PUPILS:
                mat[y, x] = "eye"
        out[stem] = to_spec(mat, SQUID_MATERIALS, src=src)
    return out


# --- axolotls -------------------------------------------------------------------
# mobs_mc_axolotl.b3d, brush 0, 64 x 64: the head box (0..26, 1..11, its
# front the -Z face 5..13, 6..11), the body, the leg, tail and gill planes.
# Much of the art lies outside the rectangles the model draws.

A_HEAD = [(5, 1, 13, 6), (13, 1, 21, 6), (0, 6, 5, 11), (5, 6, 13, 11), (13, 6, 18, 11),
          (18, 6, 26, 11)]
A_TAIL = [(2, 26, 11, 31), (2, 31, 14, 36)]
A_GILLS = [(3, 37, 11, 40), (0, 40, 3, 47), (11, 40, 14, 47)]
A_LEGS = [(2, 13, 5, 18), (5, 13, 8, 18)]
AXOLOTLS = ["mobs_mc_axolotl_" + c for c in ("brown", "yellow", "green", "pink", "black",
                                             "purple", "white")]
# A narrow roll and a low dome: an axolotl's sides are light at the belly
# and darker above, and the 1.5 texel roll, darkening the bottom row and
# lighting the top, took the black axolotl's sides to 63% of their art
# contrast (82% now).
A_SKIN = wet(0.9, 0.4, cell=0.45, scatter=0.5, rnd=4, roll=1.0)
A_FIN = fin(0.9, 0.5)
# The gills: frilly, soft, wet, a little finer creased.
A_GILL = dict(fin(0.92, 0.45), micro_params={"cell": 0.25, "wrinkles": 2.4},
              micro_strength=0.25)
A_MOUTH = {"mode": "flat", "base": 0.82, "span": 0.0, "micro": "none", "smooth": 0.55,
           "smooth_spread": 0.0, "scatter": 0.3}
AXOLOTL_MATERIALS = {"skin": A_SKIN, "fin": A_FIN, "gill": A_GILL, "mouth": A_MOUTH,
                     "eye": eye(0.9)}


def axolotl_specs():
    out = {}
    w, h = 64, 64
    for stem in AXOLOTLS:
        src = lib.load_source(stem, GAME)
        mat = np.full((h, w), "skin", dtype=object)
        for r in A_HEAD:
            x0, y0, x1, y1 = r
            face = [lum(src[y, x, :3]) for y in range(y0, y1) for x in range(x0, x1)
                    if src[y, x, 3] >= 0.5]
            if not face:
                continue
            med = float(np.median(face))
            for y in range(y0, y1):
                for x in range(x0, x1):
                    if src[y, x, 3] < 0.5:
                        continue
                    L = lum(src[y, x, :3])
                    if y in (9, 10) and y0 >= 6 and L < med - 0.1:
                        mat[y, x] = "mouth"
                    elif 6 <= y <= 8 and y0 >= 6 and L < 0.7 * med:
                        mat[y, x] = "eye"
        paint_drawn(mat, src, A_TAIL + A_LEGS, "fin")
        paint_drawn(mat, src, A_GILLS, "gill")
        out[stem] = to_spec(mat, AXOLOTL_MATERIALS, CUTOUT, src)
    return out


def paint_drawn(mat, src, rects, name):
    for x0, y0, x1, y1 in rects:
        for y in range(y0, y1):
            for x in range(x0, x1):
                if src[y, x, 3] >= 0.5:
                    mat[y, x] = name


# --- dolphin --------------------------------------------------------------------
# extra_mobs_dolphin.b3d, brush -1, 64 x 64.

D_HEAD = [(0, 0, 28, 13)]
D_SNOUT = [(0, 13, 12, 19)]
D_FINS = [(48, 20, 64, 31), (51, 0, 63, 9), (19, 20, 51, 27)]
D_SKIN = wet(0.9, 0.55, cell=0.6, micro_strength=0.15, scatter=0.25)
# The rostrum: proud and smooth like the cow's muzzle.
D_SNOUT_M = dict(wet(1.0, 0.6, span=0.04, micro_strength=0.12, cell=0.4, rnd=6, roll=1))
DOLPHIN_MATERIALS = {"skin": D_SKIN, "snout": D_SNOUT_M, "fin": fin(0.9, 0.55),
                     "eye": eye(0.92)}


def dolphin_specs():
    stem = "extra_mobs_dolphin"
    src = lib.load_source(stem, GAME)
    h, w = src.shape[:2]
    mat = np.full((h, w), "skin", dtype=object)
    for y, x in drawn_texels(src):
        if in_rects(x, y, D_HEAD) and lum(src[y, x, :3]) < 0.25:
            mat[y, x] = "eye"
        elif in_rects(x, y, D_SNOUT):
            mat[y, x] = "snout"
        elif in_rects(x, y, D_FINS):
            mat[y, x] = "fin"
    return {stem: to_spec(mat, DOLPHIN_MATERIALS, src=src)}


# --- fish -----------------------------------------------------------------------
# Cod and salmon: scaled bodies, a head of the same skin a little smoother,
# fins and tails as thin wet membranes, dark eyes. Each by its own faces.

F_SCALE = scales(0.84, 0.5)
F_HEAD = dict(scales(0.86, 0.55, strength=0.12), micro="hide",
              micro_params={"cell": 0.5, "wrinkles": 0.4})
F_FIN = fin(0.9, 0.5)
F_LIP = dict(wet(0.98, 0.58, span=0.04, micro_strength=0.12, cell=0.4, rnd=6, roll=1))
FISH_MATERIALS = {"scale": F_SCALE, "head": F_HEAD, "fin": F_FIN, "lip": F_LIP,
                  "eye": eye(0.9)}

C_HEAD = [(11, 3, 21, 7), (14, 0, 18, 3)]
C_LIP = [(0, 0, 6, 4)]
C_FINS = [(22, 7, 26, 11), (26, 4, 28, 6), (21, 0, 23, 1), (29, 0, 32, 1)]
C_EYES = [(12, 4), (17, 4)]
SA_HEAD = [(22, 0, 32, 7)]
SA_FINS = [(0, 0, 2, 2), (4, 0, 6, 2), (6, 4, 8, 6), (5, 6, 8, 8), (26, 16, 32, 21)]
SA_EYES = [(23, 4), (28, 4)]


def fish_spec(stem, model, brush, head, lip, fins, eyes):
    src = lib.load_source(stem, GAME)
    h, w = src.shape[:2]
    rects = face_rects(model, brush, w, h)
    mat = np.full((h, w), "scale", dtype=object)
    for y, x in drawn_texels(src):
        if not in_rects(x, y, rects):
            continue
        if in_rects(x, y, head):
            mat[y, x] = "head"
        elif in_rects(x, y, lip):
            mat[y, x] = "lip"
        elif in_rects(x, y, fins):
            mat[y, x] = "fin"
    for x, y in eyes:
        mat[y, x] = "eye"
    return to_spec(mat, FISH_MATERIALS, CUTOUT, src)


def fish_specs():
    return {
        "extra_mobs_cod": fish_spec("extra_mobs_cod", "extra_mobs_cod.b3d", -1, C_HEAD, C_LIP,
                                    C_FINS, C_EYES),
        "extra_mobs_salmon": fish_spec("extra_mobs_salmon", "extra_mobs_salmon.b3d", 0, SA_HEAD,
                                       [], SA_FINS, SA_EYES),
    }


# --- pufferfish -----------------------------------------------------------------
# One image on three models (small, medium and big, by how puffed it is);
# the spec lists the faces of all three. The spines are the one texel wide
# faces, the fins the two small planes, the eyes and mouth by colour.

PUFF_MODELS = ["mobs_mc_pufferfish_small.b3d", "mobs_mc_pufferfish_medium.b3d",
               "mobs_mc_pufferfish_big.b3d"]
PUFF_FINS = [(26, 0, 28, 5)]
PUFF_EYE = (0x22, 0x24, 0x30)
PUFF_MOUTH = (0xa3, 0x72, 0x5d)
# A pufferfish's skin is leathery, not scaled: wet, a little waxy.
PUFF_SKIN = dict(wet(0.88, 0.5, span=0.06, cell=0.4, micro_strength=0.25, scatter=0.3))
# Spines: one texel thin, hard and a little satin, rounded at the box edge.
PUFF_SPINE = {"mode": "soft", "base": 0.94, "span": 0.02, "detail": 0.25, "soft_edge": 0.3,
              "round": 2, "edge_roll": 1, "edge_lean": 20, "roll_rough": 0.05, "smooth": 0.5,
              "smooth_spread": 0.0, "micro": "bone", "micro_strength": 0.2,
              "micro_params": {"cracks": 0.1}}
PUFF_MATERIALS = {"skin": PUFF_SKIN, "spine": PUFF_SPINE, "fin": fin(0.9, 0.5),
                  "mouth": dict(A_MOUTH, ride=True, edge_roll=1, edge_lean=20, roll_rough=0.03),
                  "eye": dict(eye(0.9), ride=True, edge_roll=1, edge_lean=20, roll_rough=0.03)}


def pufferfish_specs():
    stem = "mobs_mc_pufferfish"
    src = lib.load_source(stem, GAME)
    h, w = src.shape[:2]
    faces = []
    for m in PUFF_MODELS:
        for r in face_rects(m, 0, w, h):
            if list(r) not in faces:
                faces.append(list(r))
    faces.sort(key=lambda r: (r[1], r[0]))
    spines = [r for r in faces if min(r[2] - r[0], r[3] - r[1]) == 1
              and max(r[2] - r[0], r[3] - r[1]) >= 5]
    mat = np.full((h, w), "skin", dtype=object)
    for y, x in drawn_texels(src):
        c = tuple(int(round(v * 255)) for v in src[y, x, :3])
        if c == PUFF_EYE:
            mat[y, x] = "eye"
        elif c == PUFF_MOUTH:
            mat[y, x] = "mouth"
        elif in_rects(x, y, PUFF_FINS):
            mat[y, x] = "fin"
        elif in_rects(x, y, spines):
            mat[y, x] = "spine"
    return {stem: to_spec(mat, PUFF_MATERIALS, {"faces": faces}, src)}


# --- tropical fish --------------------------------------------------------------
# Two bodies, a and b, each with six pattern overlays drawn over it with ^.
# Both are grey art the game colours. The pattern takes the body's own
# scales at the body's height, so a stripe is colour on one surface, not a
# groove; its black texels are the eyes.

# The fin planes; the rest of each model is the body box.
TF_FINS = {"a": [(28, 0, 32, 3), (17, 1, 22, 4), (2, 12, 4, 14), (2, 16, 4, 18)],
           "b": [(20, 18, 26, 30), (2, 12, 4, 14), (2, 16, 4, 18)]}
TF_SCALE = dict(scales(0.92, 0.55, levels=2, span=0.06), mode="soft", round=4,
                soft_edge=0.4, edge_roll=1, edge_lean=12, roll_rough=0.05)
TF_SCALE = {k: v for k, v in TF_SCALE.items() if k not in ("levels", "joints")}
TF_FIN = fin(0.92, 0.5)
TROPICAL_MATERIALS = {"scale": TF_SCALE, "fin": TF_FIN, "eye": eye(0.92)}
TF_PATTERN_SCALE = {"mode": "flat", "base": 0.92, "span": 0.0, "smooth": 0.55,
                    "smooth_spread": 0.0, "micro": "scale", "micro_strength": 0.25,
                    "micro_params": {"length": 0.6, "width": 0.6}}
TF_PATTERN_FIN = dict(TF_PATTERN_SCALE, micro="hide", micro_strength=0.15,
                      micro_params={"cell": 0.35, "wrinkles": 1.6})


def tropical_specs():
    out = {}
    for kind in ("a", "b"):
        stem = "extra_mobs_tropical_fish_" + kind
        src = lib.load_source(stem, GAME)
        h, w = src.shape[:2]
        fins = TF_FINS[kind]
        mat = np.full((h, w), "scale", dtype=object)
        for y, x in drawn_texels(src):
            if lum(src[y, x, :3]) < 0.08:
                mat[y, x] = "eye"
            elif in_rects(x, y, fins):
                mat[y, x] = "fin"
        out[stem] = to_spec(mat, TROPICAL_MATERIALS, dict(CUTOUT, surface=0.92), src)
        for i in range(1, 7):
            pst = "extra_mobs_tropical_fish_pattern_%s_%d" % (kind, i)
            psrc = lib.load_source(pst, GAME)
            pm = np.full((h, w), "scale", dtype=object)
            for y, x in drawn_texels(psrc):
                if lum(psrc[y, x, :3]) < 0.08:
                    pm[y, x] = "eye"
                elif in_rects(x, y, fins):
                    pm[y, x] = "fin"
            out[pst] = to_spec(pm, {"scale": TF_PATTERN_SCALE, "fin": TF_PATTERN_FIN,
                                    "eye": eye(0.92)},
                               {"overlay": True, "surface": 0.92}, psrc)
    return out


FAMILIES = {"rabbit": rabbit_specs, "parrot": parrot_specs, "polarbear": polarbear_specs,
            "bat": bat_specs, "slime": slime_specs, "snowman": snowman_specs,
            "mushroom": mushroom_specs, "squid": squid_specs, "axolotl": axolotl_specs,
            "dolphin": dolphin_specs, "fish": fish_specs, "pufferfish": pufferfish_specs,
            "tropical": tropical_specs}

# The model and brush each stem is listed with in stems/<game>.mobs.txt.
MODELS = {}
for _s in RABBITS:
    MODELS[_s] = ("mobs_mc_rabbit.b3d", 0)
for _s in PARROTS:
    MODELS[_s] = ("mobs_mc_parrot.b3d", -1)
for _s in AXOLOTLS:
    MODELS[_s] = ("mobs_mc_axolotl.b3d", 0)
MODELS.update({
    "mobs_mc_polarbear": ("mobs_mc_polarbear.b3d", -1),
    "mobs_mc_bat": ("mobs_mc_bat.b3d", 0),
    "mobs_mc_slime": ("mobs_mc_slime.b3d", 0),
    "mobs_mc_snowman": ("mobs_mc_snowman.b3d", 0),
    "mobs_mc_mushroom_red": ("mobs_mc_cow.b3d", 1),
    "mobs_mc_mushroom_brown": ("mobs_mc_cow.b3d", 1),
    "mobs_mc_squid": ("mobs_mc_squid.b3d", -1),
    "extra_mobs_glow_squid": ("mobs_mc_squid.b3d", -1),
    "extra_mobs_dolphin": ("extra_mobs_dolphin.b3d", -1),
    "extra_mobs_cod": ("extra_mobs_cod.b3d", -1),
    "extra_mobs_salmon": ("extra_mobs_salmon.b3d", 0),
    "mobs_mc_pufferfish": ("mobs_mc_pufferfish_big.b3d", 0),
})
for _k in ("a", "b"):
    MODELS["extra_mobs_tropical_fish_" + _k] = ("extra_mobs_tropical_fish_%s.b3d" % _k, 0)
    for _i in range(1, 7):
        MODELS["extra_mobs_tropical_fish_pattern_%s_%d" % (_k, _i)] = (
            "extra_mobs_tropical_fish_%s.b3d" % _k, 0)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check_only = "--check" in sys.argv
    if "--list" in sys.argv:
        for name in args or list(FAMILIES):
            for stem in FAMILIES[name]():
                model, brush = MODELS[stem]
                print("%s %s%s" % (stem, model, "" if brush == 0 else " %d" % brush))
        return
    stale = []
    for name in args or list(FAMILIES):
        for stem, spec in FAMILIES[name]().items():
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
