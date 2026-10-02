"""Specs for families of near identical mob skins: ridden mobs and pets.

A horse comes in seven coats, a wolf in nine with an angry and a tame face
each, a cat in twelve, a llama in five with seventeen carpets. Every coat
of one family is the same layout on the same model, so its spec is the
same grid of parts with only the colours changed, and writing them by hand
would be eighty copies of one decision. This writes them instead:

  part map   one part name per art texel, from the model's own faces (the
             face rectangles each box draws, listed per family below from
             atlas.faces) and, for the horse, which mesh of the model the
             face belongs to (0 the chest bags, 1 the body, 2 the saddle
             and bridle).
  refine     a few rules per family that read the stem's own art: the eye
             and nostril texels at their fixed places, the red of a mouth,
             the grey of a buckle, the toes of a llama, the teeth an angry
             wolf bares. These are the only things that differ by coat.
  materials  one table per family (FUR, MANE and so on below), the same for
             every coat, so a cow's fur, a horse's fur and a wolf's fur are
             the one decision, judged once.

and writes specs/mineclonia/<stem>.json, a full grid with a legend like a
hand written spec. The specs are what atlas.py reads; this script is how
they were made. Change a material or a rule here and run it again, then
build and check as for any spec:

    python3 tools/pbr_author/mob_families.py            # write every spec
    python3 tools/pbr_author/mob_families.py --check    # exit 1 if any differs
    python3 tools/pbr_author/mob_families.py horse      # one family

Manes and tails are hair. For now they take the fur treatment with locks
by shade, lighter higher, and lock_round's soft roll in place of the crisp
chamfer; they are the materials named "mane" and "tail" so that they can
move to the hair shader in one place.
"""
import colorsys
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import atlas  # noqa: E402
import lib  # noqa: E402

GAME = "mineclonia"
SPECS = Path(__file__).resolve().parent / "specs" / GAME

# The cow's spec keys, which the owner approved ("the snout looks perfect").
HEAD = {
    "class": "cloth",
    "texel_px": 16,
    "strength": 24.0,
    "chamfer": 2,
    "face_edge": "bevel",
    "bevel_px": 3,
    "bevel_depth": 0.07,
    "micro": "none",
}

# --- materials ----------------------------------------------------------------
# Heights: main surfaces near the top of the range (the client lifts each
# face's highest texel onto the face), shade steps 0.10 to 0.18 of the range
# inside a material so parallax keeps the art legible.

# The cow's coat: per texel by shade, soft and matte, an undirected mottle.
FUR = {"mode": "shade", "base": 0.74, "span": 0.14, "levels": 3, "detail": 0.25, "joints": False,
       "smooth": 0.14, "smooth_spread": 0.04, "micro": "mottle", "micro_params": {"cell": 0.5},
       "micro_strength": 0.15, "micro_swing": 0.3}
# A wolf's ruff and a llama's fleece stand a little prouder than the coat.
LONG_FUR = dict(FUR, base=0.8, micro_params={"cell": 0.6}, micro_strength=0.18)
# A wolf's and a cat's coat: the cow's fur with shallower steps. Their
# boxes are small and tucked behind a ruff or a head, so a top seen at a
# grazing angle has its row beside the taller box slide under it; at the
# cow's 0.14 a wolf's back kept 88% of its texels.
PET_FUR = dict(FUR, base=0.76, span=0.1)
# A llama's fleece is drawn as near uniform cream with a faint noise of
# shades; a crisp step per texel turned that into a crazing of chamfer
# lines, like cracked plaster. Soft instead: lighter a little higher in
# proportion, the steps rounded, the box edges rolled.
FLEECE = {"mode": "soft", "base": 0.9, "span": 0.08, "detail": 0.25, "soft_edge": 0.4, "round": 4,
          "edge_roll": 1.5, "edge_lean": 15, "roll_rough": 0.03, "smooth": 0.14,
          "smooth_spread": 0.02, "micro": "mottle", "micro_params": {"cell": 0.6},
          "micro_strength": 0.2, "micro_swing": 0.3, "scatter": 0.3}
# Hair: locks by shade, lighter higher, each step rolled off over about a
# third of a texel (lock_round) and the box edges rolled, not bevelled.
# For the hair shader later.
MANE = {"mode": "shade", "base": 0.84, "span": 0.1, "levels": 3, "detail": 0.3, "joints": False,
        "lock_round": 0.3, "edge_roll": 1.5, "edge_lean": 15, "roll_rough": 0.03,
        "smooth": 0.2, "smooth_spread": 0.04, "micro": "mottle", "micro_params": {"cell": 0.4},
        "micro_strength": 0.12, "micro_swing": 0.3}
TAIL = dict(MANE)
# A wolf's or cat's tail is two texels wide and mostly hidden behind the
# body at a three quarter view; flatter locks keep its few visible texels.
PET_TAIL = dict(MANE, base=0.86, span=0.08)
# The cow's snout pad, nostrils, eyes and hooves.
MUZZLE = {"mode": "flat", "base": 1.0, "span": 0.0, "micro": "hide", "smooth": 0.62,
          "smooth_spread": 0.0, "micro_params": {"cell": 0.4, "wrinkles": 1.2},
          "micro_strength": 0.3, "scatter": 0.25, "wear": 0.05}
NOSTRIL = {"mode": "flat", "base": 0.76, "span": 0.0, "micro": "none", "smooth": 0.7,
           "smooth_spread": 0.0}
EYE = {"mode": "flat", "base": 0.76, "span": 0.0, "micro": "none", "smooth": 0.9,
       "smooth_spread": 0.0, "f0": 0.06}
HOOF = {"mode": "flat", "base": 0.92, "span": 0.0, "micro": "bone", "smooth": 0.5,
        "smooth_spread": 0.0, "micro_strength": 0.3, "micro_params": {"cracks": 0.8}}
# Ears are small boxes seen edge on: one height each, as the cow's, so
# parallax keeps both of their shades (a stepped ear front kept 83%).
EAR = {"mode": "flat", "base": 0.82, "span": 0.0, "micro": "mottle", "micro_params": {"cell": 0.5},
       "micro_strength": 0.15, "micro_swing": 0.3, "smooth": 0.16, "smooth_spread": 0.0}
# Inside a mouth: gums and tongue soft and wet, teeth bone, the throat sunk.
GUM = {"mode": "soft", "base": 0.84, "span": 0.06, "detail": 0.25, "soft_edge": 0.3, "round": 6,
       "edge_roll": 1, "edge_lean": 12, "roll_rough": 0.03, "smooth": 0.55, "smooth_spread": 0.02,
       "micro": "hide", "micro_params": {"cell": 0.35}, "micro_strength": 0.2, "scatter": 0.45}
TEETH = {"mode": "flat", "base": 0.94, "span": 0.0, "micro": "bone", "smooth": 0.55,
         "smooth_spread": 0.0, "micro_strength": 0.2, "micro_params": {"cracks": 0.2}}
THROAT = {"mode": "flat", "base": 0.74, "span": 0.0, "micro": "none", "smooth": 0.4,
          "smooth_spread": 0.0}
# A dog's or cat's nose and the pads of its paws: soft, leathery, a little
# moist, rolled at the box edge instead of bevelled.
NOSE = {"mode": "soft", "base": 0.96, "span": 0.04, "detail": 0.25, "soft_edge": 0.3, "round": 8,
        "edge_roll": 1, "edge_lean": 15, "roll_rough": 0.05, "smooth": 0.58, "smooth_spread": 0.02,
        "micro": "hide", "micro_params": {"cell": 0.3, "wrinkles": 0.4}, "micro_strength": 0.25,
        "scatter": 0.3}
PAD = dict(NOSE, base=0.9, smooth=0.36, round=6)
# A wolf's or cat's snout: short fur, proud of the face, flatter steps.
SNOUT = dict(FUR, base=0.86, span=0.1, levels=2, smooth=0.18, micro_params={"cell": 0.35})
# Tack: the pig saddle's leather, stitched; the seat smoother; straps plain;
# buckles, bit and stirrups worn iron.
LEATHER = {"mode": "flat", "base": 0.92, "span": 0.0, "micro": "leather", "smooth": 0.38,
           "smooth_spread": 0.0, "micro_strength": 0.4,
           "stitch": {"inset": 0.22, "length": 0.36, "gap": 0.18, "width": 0.07, "groove": 0.05,
                      "depth": 0.03},
           "wear": 0.15}
SEAT = {"mode": "flat", "base": 0.88, "span": 0.0, "micro": "leather", "smooth": 0.5,
        "smooth_spread": 0.0, "micro_strength": 0.3, "wear": 0.2}
STRAP = {"mode": "flat", "base": 0.96, "span": 0.0, "micro": "leather", "smooth": 0.34,
         "smooth_spread": 0.0, "micro_strength": 0.35, "wear": 0.12}
IRON = {"mode": "flat", "base": 1.0, "span": 0.0, "micro": "metal_worn", "smooth": 0.5,
        "smooth_spread": 0.0, "metal": True, "wear": 0.12}
# Chests: boards by shade with the grain along them, an iron latch.
WOOD = {"mode": "shade", "base": 0.8, "span": 0.12, "levels": 2, "detail": 0.3, "joints": False,
        "smooth": 0.3, "smooth_spread": 0.04, "micro": "wood", "micro_dir": "h",
        "micro_strength": 0.8}
LATCH = dict(IRON, base=1.0, smooth=0.55)
# A collar: one leather band, just proud of the fur. Higher, it became the
# highest texel of the faces it crosses, the client lifts that onto the face,
# and the coat beside it sank and slid under parallax (a cat's back kept 77%
# of its texels).
COLLAR = {"mode": "flat", "base": 0.86, "span": 0.0, "micro": "leather", "smooth": 0.42,
          "smooth_spread": 0.0, "micro_strength": 0.35, "wear": 0.1}
# Carpets: wool, felted, matte, by shade.
WOOL = {"mode": "shade", "base": 0.84, "span": 0.12, "levels": 2, "detail": 0.25, "joints": False,
        "smooth": 0.1, "smooth_spread": 0.03, "micro": "mottle", "micro_params": {"cell": 0.35},
        "micro_strength": 0.25, "scatter": 0.3}
# Undead: the skeleton's bone, the zombie's rotting skin.
BONE = {"mode": "shade", "base": 0.82, "span": 0.08, "levels": 2, "detail": 0.3, "joints": False,
        "smooth": 0.45, "smooth_spread": 0.02, "micro": "bone", "micro_strength": 1.2}
SOCKET = {"mode": "flat", "base": 0.5, "span": 0.0, "micro": "none", "smooth": 0.3,
          "smooth_spread": 0.0}
ROT = {"mode": "soft", "base": 0.92, "span": 0.08, "detail": 0.25, "micro": "rotten",
       "micro_strength": 0.8, "smooth": 0.34, "smooth_spread": 0.02, "scatter": 0.2, "wear": 0.05,
       "soft_edge": 0.3, "round": 6, "edge_roll": 2, "edge_lean": 15, "roll_rough": 0.03}
WOUND = {"mode": "flat", "base": 0.8, "span": 0.0, "micro": "rotten", "micro_strength": 0.6,
         "smooth": 0.55, "smooth_spread": 0.0, "scatter": 0.4}
BARE = dict(BONE, base=0.78, span=0.08)
# Horse armour: worn plates by shade, the very dark iron a dielectric (a
# near black metal texel is a black mirror), cloth and leather as on tack.
# The plates top out at 0.84, under the coat's 0.88: the client lifts each
# face's highest texel onto the face, so an overlay higher than the coat it
# half covers sinks the coat beside it (a horse's neck front under gold
# plates kept 76% of its texels at 0.88).
PLATE = {"mode": "shade", "base": 0.74, "span": 0.1, "levels": 3, "detail": 0.3, "joints": False,
         "metal": True, "smooth": 0.55, "smooth_spread": 0.03, "micro": "metal_worn",
         "wear": 0.14}
GEM = {"mode": "shade", "base": 0.74, "span": 0.1, "levels": 3, "detail": 0.3, "joints": False,
       "smooth": 0.82, "smooth_spread": 0.02, "f0": 0.17, "micro": "glass", "micro_strength": 0.4,
       "wear": 0.08}
DARK_IRON = {"mode": "flat", "base": 0.8, "span": 0.0, "micro": "metal_worn", "smooth": 0.4,
             "smooth_spread": 0.0, "wear": 0.1}
# The caparison under the plates is one cloth whatever its check: flat,
# so its cream squares do not stand over its red ones.
CLOTH = {"mode": "flat", "base": 0.82, "span": 0.0,
         "smooth": 0.14, "smooth_spread": 0.02, "micro": "canvas", "micro_strength": 0.7,
         "wear": 0.1, "scatter": 0.25}
HIDE_ARMOUR = {"mode": "shade", "base": 0.76, "span": 0.12, "levels": 3, "detail": 0.3,
               "joints": False, "micro": "leather", "smooth": 0.38, "smooth_spread": 0.03,
               "micro_strength": 0.4, "wear": 0.15}
ARMOUR_STRAP = dict(STRAP, base=0.84)

# --- helpers -------------------------------------------------------------------


def hsv(rgb):
    return colorsys.rgb_to_hsv(*[float(c) for c in rgb])


def lum(rgb):
    return float(lib.luminance(np.asarray(rgb, np.float32)))


def mesh_faces(model, w, h, brushes=None):
    """Per face rectangle: (mesh index, centroid y) over the model's meshes,
    for the given brushes (all when None)."""
    out = {}
    for mi, (pos, uv, tris) in enumerate(atlas.read_b3d(atlas.model_path(model, GAME))):
        for b, idx in tris:
            if brushes is not None and b not in brushes:
                continue
            for t in idx:
                u, v = uv[t, 0] * w, uv[t, 1] * h
                r = (int(round(u.min())), int(round(v.min())),
                     int(round(u.max())), int(round(v.max())))
                if r[2] > r[0] and r[3] > r[1] and r not in out:
                    out[r] = (mi, float(pos[t][:, 1].mean()))
    return out


def paint(part, rects, name):
    for x0, y0, x1, y1 in rects:
        part[y0:y1, x0:x1] = name


def write(stem, spec, check_only):
    """Write the spec as the hand written ones are laid out; True if the
    file already said exactly this."""
    lines = ["{"]
    keys = list(spec)
    for i, k in enumerate(keys):
        comma = "," if i < len(keys) - 1 else ""
        v = spec[k]
        if k == "materials":
            lines.append(' "materials": {')
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


def to_spec(mat, materials, extra=None, src=None):
    """The spec for a material map: the first material is the grid's '.',
    the rest a character each, in the order given. Texels src does not
    draw take the first."""
    if src is not None:
        mat = np.where(src[..., 3] >= 0.5, mat, list(materials)[0]).astype(object)
    chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    names = list(materials)
    used = [n for n in names if (mat == n).any()]
    keep = [names[0]] + [n for n in used if n != names[0]]
    legend = {chars[i]: n for i, n in enumerate(keep[1:])}
    sym = {n: c for c, n in legend.items()}
    sym[names[0]] = "."
    grid = ["".join(sym[m] for m in row) for row in mat]
    spec = dict(HEAD)
    spec.update(extra or {})
    spec["materials"] = {n: materials[n] for n in keep}
    spec["grid"] = grid
    spec["legend"] = legend
    return spec


# --- horses, donkey, mule, armour ----------------------------------------------
# mobs_mc_horse.b3d draws one image on three meshes (brush 0 each): the chest
# bags, the body and the tack. Luanti gives each mesh buffer its own texture
# from the list (chest, coat, saddle), all the coat's image, so the saddle and
# chest are drawn from the coat's own atlas. Face rectangles from atlas.faces.

H_EARS = [(1, 0, 3, 1), (3, 0, 5, 1), (0, 1, 1, 4), (1, 1, 3, 4), (3, 1, 4, 4), (4, 1, 6, 4),
          (1, 12, 3, 13), (3, 12, 5, 13), (0, 13, 1, 20), (1, 13, 3, 20), (3, 13, 4, 20),
          (4, 13, 6, 20)]
H_HEAD = [(7, 0, 12, 7), (12, 0, 17, 7), (0, 7, 7, 12), (7, 7, 12, 12), (12, 7, 19, 12),
          (19, 7, 24, 12)]
H_MUZZLE = [(30, 18, 34, 24), (24, 24, 30, 27), (30, 24, 34, 27), (34, 24, 40, 27),
            (40, 24, 44, 27), (24, 32, 29, 34), (29, 32, 33, 34), (33, 32, 38, 34),
            (38, 32, 42, 34), (33, 27, 37, 32)]
# The palate (the upper jaw's underside) and the lower jaw's top.
H_MOUTH = [(34, 18, 38, 24), (29, 27, 33, 32)]
H_MANE = [(62, 0, 64, 4), (64, 0, 66, 4), (58, 4, 62, 20), (62, 4, 64, 20), (64, 4, 68, 20),
          (68, 4, 70, 20)]
H_TAIL = [(47, 0, 49, 3), (49, 0, 51, 3), (31, 3, 34, 10), (34, 3, 37, 10), (44, 3, 47, 5),
          (47, 3, 49, 5), (49, 3, 52, 5), (52, 3, 54, 5), (45, 7, 48, 14), (48, 7, 51, 14),
          (24, 10, 31, 14), (31, 10, 34, 14), (34, 10, 41, 14), (41, 10, 44, 14),
          (38, 14, 45, 18), (45, 14, 48, 18), (48, 14, 55, 18), (55, 14, 58, 18)]
H_EYES = [(4, 8), (14, 8)]
H_NOSTRILS = [(30, 24), (33, 24)]
H_SEAT = [(88, 0, 98, 8)]
H_SADDLE = [(80, 0, 116, 12)]


def horse_parts(w, h):
    part = np.full((h, w), "leg", dtype=object)
    faces = mesh_faces("mobs_mc_horse.b3d", w, h)
    for r, (mi, cy) in faces.items():
        if mi == 0:
            paint(part, [r], "chest")
        elif mi == 2:
            paint(part, [r], "tack")
        elif cy <= 0.65 and r[1] >= 51:
            # The hoof box: its sides' lower two rows and its sole are hoof,
            # its top row the pastern above (the coat's colour).
            x0, y0, x1, y1 = r
            if cy < 0.15:
                paint(part, [r], "hoof")
            elif cy < 0.45:
                paint(part, [(x0, y0 + 1, x1, y1)], "hoof")
    paint(part, H_EARS, "ear")
    paint(part, H_HEAD, "fur")
    paint(part, [(8, 12, 12, 20), (12, 12, 16, 20), (0, 20, 24, 34)], "fur")
    paint(part, [(0, 58, 68, 68), (24, 34, 44, 58)], "fur")
    paint(part, H_MUZZLE, "muzzle")
    paint(part, H_MOUTH, "mouth")
    paint(part, H_MANE, "mane")
    paint(part, H_TAIL, "tail")
    return part


def horse_materials(stem, src, part, undead=None):
    """The material per texel for one horse image."""
    h, w = part.shape
    mat = np.full((h, w), "fur", dtype=object)
    drawn = src[..., 3] >= 0.5
    for y in range(h):
        for x in range(w):
            if not drawn[y, x]:
                continue
            p = part[y, x]
            rgb = src[y, x, :3]
            hh, s, v = hsv(rgb)
            L = lum(rgb)
            m = "fur"
            if p in ("mane", "tail", "muzzle", "ear", "hoof"):
                m = p
            elif p == "leg":
                m = "fur"
            elif p == "mouth":
                # Red gums and tongue, cream teeth, and the dark row at the
                # back of the palate, the throat.
                if s > 0.45:
                    m = "gum"
                elif L >= 0.55:
                    m = "teeth"
                else:
                    m = "throat"
            elif p == "tack":
                if s < 0.16 and L > 0.25:
                    m = "iron"
                elif any(x0 <= x < x1 and y0 <= y < y1 for x0, y0, x1, y1 in H_SEAT):
                    m = "seat"
                elif any(x0 <= x < x1 and y0 <= y < y1 for x0, y0, x1, y1 in H_SADDLE):
                    m = "leather"
                else:
                    m = "strap"
            elif p == "chest":
                m = "latch" if (s < 0.16 and L > 0.25) else "wood"
            mat[y, x] = m
    if undead is None:
        for x, y in H_EYES:
            if drawn[y, x]:
                mat[y, x] = "eye"
        for x, y in H_NOSTRILS:
            if drawn[y, x]:
                mat[y, x] = "nostril"
    return mat


HORSE_MATERIALS = {"fur": FUR, "mane": MANE, "tail": TAIL, "ear": EAR, "muzzle": MUZZLE,
                   "nostril": NOSTRIL, "eye": EYE, "gum": GUM, "teeth": TEETH, "throat": THROAT,
                   "hoof": HOOF, "leather": LEATHER, "seat": SEAT, "strap": STRAP, "iron": IRON,
                   "wood": WOOD, "latch": LATCH}

HORSE_COATS = ["mobs_mc_horse_" + c for c in
               ("black", "brown", "chestnut", "creamy", "darkbrown", "gray", "white")]
HORSE_MARKINGS = ["mobs_mc_horse_markings_" + c for c in
                  ("blackdots", "white", "whitedots", "whitefield")]
HORSE_ARMOUR = ["mcl_mobitems_horse_armor_" + c for c in
                ("leather", "leather_desat", "copper", "iron", "gold", "diamond")]


def horse_specs():
    out = {}
    w = h = 128
    part = horse_parts(w, h)
    for stem in HORSE_COATS + ["mobs_mc_donkey", "mobs_mc_mule"]:
        src = lib.load_source(stem, GAME)
        out[stem] = to_spec(horse_materials(stem, src, part), HORSE_MATERIALS, src=src)
    # Markings are ^ overlays of the coat: white or black fur, and the
    # stockings repaint the hooves.
    for stem in HORSE_MARKINGS:
        src = lib.load_source(stem, GAME)
        mat = horse_materials(stem, src, part, undead=True)
        # The sooty dots are one colour: flat, which the release gate
        # accepts as relief in the normal only.
        fur = dict(FUR, mode="flat", base=0.78, span=0.0) if stem.endswith("blackdots") else FUR
        out[stem] = to_spec(mat, {"fur": fur, "mane": MANE, "tail": TAIL, "ear": EAR,
                                  "muzzle": MUZZLE, "hoof": HOOF},
                            {"overlay": True, "surface": 0.81}, src)
    # The skeleton horse: bone, the sockets and the dark between the ribs
    # sunk; its tack is the living horse's.
    src = lib.load_source("mobs_mc_horse_skeleton", GAME)
    mat = horse_materials("mobs_mc_horse_skeleton", src, part, undead=True)
    drawn = src[..., 3] >= 0.5
    for y, x in zip(*np.nonzero(drawn)):
        if mat[y, x] in ("fur", "ear", "muzzle", "mane", "tail", "hoof", "teeth", "gum"):
            mat[y, x] = "socket" if lum(src[y, x, :3]) < 0.1 else "bone"
    out["mobs_mc_horse_skeleton"] = to_spec(
        mat, {"bone": BONE, "socket": SOCKET, "throat": THROAT, "leather": LEATHER, "seat": SEAT,
              "strap": STRAP, "iron": IRON}, src=src)
    # The zombie horse: rotting skin, bone where it shows through, red
    # wounds, a dark mane and tail.
    src = lib.load_source("mobs_mc_horse_zombie", GAME)
    mat = horse_materials("mobs_mc_horse_zombie", src, part, undead=True)
    drawn = src[..., 3] >= 0.5
    for y, x in zip(*np.nonzero(drawn)):
        m = mat[y, x]
        if m in ("leather", "seat", "strap", "iron", "mane", "tail"):
            continue
        rgb = src[y, x, :3]
        hh, s, v = hsv(rgb)
        if s < 0.2 and lum(rgb) > 0.4:
            mat[y, x] = "bone"
        elif (hh < 0.03 or hh > 0.93) and s > 0.6:
            mat[y, x] = "wound"
        elif m == "hoof":
            mat[y, x] = "hoof"
        else:
            mat[y, x] = "skin"
    out["mobs_mc_horse_zombie"] = to_spec(
        mat, {"skin": ROT, "bone": BARE, "wound": WOUND, "mane": MANE, "tail": TAIL, "hoof": HOOF,
              "leather": LEATHER, "seat": SEAT, "strap": STRAP, "iron": IRON}, src=src)
    # Horse armour, a ^ overlay of the coat. Every armour is one layout;
    # its materials come from its own palette.
    leather_mat = None
    for stem in HORSE_ARMOUR:
        src = lib.load_source(stem, GAME)
        drawn = src[..., 3] >= 0.5
        mat = np.full((h, w), "plate", dtype=object)
        kind = stem.rsplit("_", 1)[-1]
        for y, x in zip(*np.nonzero(drawn)):
            rgb = src[y, x, :3]
            hh, s, v = hsv(rgb)
            L = lum(rgb)
            if kind in ("leather", "desat"):
                m = "dark" if 0.55 < hh < 0.7 else "hide"
            elif kind == "diamond":
                m = "gem" if s > 0.3 or L > 0.6 else ("strap" if hh < 0.1 and s > 0.3 else "dark")
                if 0.03 < hh < 0.1 and s > 0.35:
                    m = "strap"
            elif kind == "gold":
                if 0.06 < hh < 0.16 and s > 0.5:
                    m = "plate" if L >= 0.21 else "dark"
                elif 0.6 < hh < 0.85 and s > 0.3:
                    m = "cloth"
                elif 0.03 < hh < 0.1 and s > 0.35:
                    m = "strap"
                else:
                    m = "dark"
            else:
                # Iron and copper: the plates; red and cream cloth; the
                # brown strap; the blue black of the eye holes and joints.
                if (hh < 0.03 or hh > 0.95) and s > 0.5:
                    m = "cloth"
                elif 0.03 <= hh < 0.07 and 0.4 < s < 0.5 and L < 0.2:
                    m = "strap"
                elif 0.55 < hh < 0.7:
                    m = "dark"
                elif 0.08 < hh < 0.14 and 0.09 < s < 0.17 and L > 0.6:
                    m = "cloth"
                else:
                    m = "plate" if L >= 0.21 else "dark"
            mat[y, x] = m
        if kind == "leather":
            leather_mat = mat
        if kind == "desat" and leather_mat is not None:
            # The grey copy that leather dyes are multiplied onto: the
            # leather's own map, since its hues are gone.
            mat = leather_mat.copy()
        if kind in ("leather", "desat"):
            mats = {"hide": HIDE_ARMOUR, "dark": DARK_IRON}
        elif kind == "diamond":
            mats = {"gem": GEM, "dark": DARK_IRON, "strap": ARMOUR_STRAP}
        else:
            mats = {"plate": PLATE, "dark": DARK_IRON, "cloth": CLOTH, "strap": ARMOUR_STRAP}
        out[stem] = to_spec(mat, mats, {"overlay": True, "surface": 0.81}, src)
    return out


# --- llamas ----------------------------------------------------------------------
# mobs_mc_llama.b3d: brush 0 the chest bags, 1 the carpet, 2 the coat. The
# chest is drawn from the coat's image, so a coat's faces are brush 2's and
# brush 0's, given to atlas.py as the spec's "faces".

L_SNOUT = [(9, 0, 13, 9), (13, 0, 17, 9), (0, 9, 9, 13), (9, 9, 13, 13), (13, 9, 22, 13),
           (22, 9, 26, 13)]
L_EARS = [(19, 0, 22, 2), (22, 0, 25, 2), (17, 2, 19, 5), (19, 2, 22, 5), (22, 2, 24, 5),
          (24, 2, 27, 5)]
L_EYES = [(7, 21), (8, 21), (7, 22), (8, 22), (11, 21), (12, 21), (11, 22), (12, 22)]
L_NOSTRILS = [(9, 10), (12, 10)]
L_MOUTH = [(10, 11), (11, 11)]
L_SOLE = [(37, 29, 41, 33)]
L_LEGS = [(33, 29, 37, 33), (29, 33, 45, 47)]


def llama_faces(w, h, brushes):
    seen = []
    for r in mesh_faces("mobs_mc_llama.b3d", w, h, brushes):
        seen.append(list(r))
    return sorted(seen, key=lambda r: (r[1], r[0]))


def llama_specs():
    out = {}
    w, h = 128, 64
    faces = llama_faces(w, h, {0, 2})
    chest = mesh_faces("mobs_mc_llama.b3d", w, h, {0})
    for stem in ["mobs_mc_llama"] + ["mobs_mc_llama_" + c for c in
                                     ("brown", "creamy", "gray", "white")]:
        src = lib.load_source(stem, GAME)
        drawn = src[..., 3] >= 0.5
        part = np.full((h, w), "fleece", dtype=object)
        paint(part, list(chest), "chest")
        paint(part, L_SNOUT, "muzzle")
        paint(part, L_EARS, "ear")
        paint(part, L_LEGS, "leg")
        paint(part, L_SOLE, "hoof")
        mat = np.full((h, w), "fleece", dtype=object)
        legs = np.zeros((h, w), bool)
        paint(legs, L_LEGS, True)
        leg_l = np.array([lum(src[y, x, :3]) for y, x in zip(*np.nonzero(legs & drawn))])
        leg_ref = float(np.median(leg_l)) if leg_l.size else 0.0
        for y, x in zip(*np.nonzero(drawn)):
            p = part[y, x]
            rgb = src[y, x, :3]
            hh, s, v = hsv(rgb)
            if p == "chest":
                m = "latch" if (s < 0.16 and lum(rgb) > 0.25) else "wood"
            elif p == "leg":
                # Toes: the darker marks in the lowest two rows of a leg.
                m = "hoof" if (y >= 45 and lum(rgb) < 0.85 * leg_ref) else "fleece"
            else:
                m = p
            mat[y, x] = m
        for x, y in L_EYES:
            mat[y, x] = "eye"
        for x, y in L_NOSTRILS:
            mat[y, x] = "nostril"
        for x, y in L_MOUTH:
            mat[y, x] = "nostril"
        out[stem] = to_spec(mat, {"fleece": FLEECE, "muzzle": MUZZLE, "nostril": NOSTRIL,
                                  "eye": EYE, "ear": EAR, "hoof": HOOF, "wood": WOOD,
                                  "latch": LATCH},
                            {"faces": faces}, src)
    # Carpets, on their own slightly larger boxes (brush 1): wool. Built as
    # an overlay, as the pig's saddle is, so the texels it leaves
    # transparent stand at the wool's height and its straps do not chamfer
    # down into the holes between them.
    for c in ("black", "blue", "brown", "cyan", "gray", "green", "light_blue", "light_gray",
              "lime", "magenta", "orange", "pink", "purple", "red", "wandering_trader", "white",
              "yellow"):
        stem = "mobs_mc_llama_decor_" + c
        src = lib.load_source(stem, GAME)
        mat = np.full((h, w), "wool", dtype=object)
        out[stem] = to_spec(mat, {"wool": WOOL}, {"overlay": True, "surface": 0.9}, src)
    return out


# --- wolves ---------------------------------------------------------------------
# mobs_mc_wolf.b3d, brush 0 (1 and 2 are its armour, blank).

W_HEAD = [(4, 0, 10, 4), (10, 0, 16, 4), (0, 4, 4, 10), (4, 4, 10, 10), (10, 4, 14, 10),
          (14, 4, 20, 10)]
W_SNOUT = [(4, 10, 7, 14), (7, 10, 10, 14), (0, 14, 4, 17), (4, 14, 7, 17), (7, 14, 11, 17),
           (11, 14, 14, 17)]
W_EARS = [(17, 14, 19, 15), (19, 14, 21, 15), (16, 15, 17, 17), (17, 15, 19, 17),
          (19, 15, 20, 17), (20, 15, 22, 17)]
W_RUFF = [(28, 0, 36, 7), (36, 0, 44, 7), (21, 7, 28, 13), (28, 7, 36, 13), (36, 7, 43, 13),
          (43, 7, 51, 13)]
W_TAIL = [(11, 18, 13, 20), (13, 18, 15, 20), (9, 20, 11, 28), (11, 20, 13, 28),
          (13, 20, 15, 28), (15, 20, 17, 28)]
W_PADS = [(4, 18, 6, 20)]
W_NOSE = [(5, 14)]
WOLF_COATS = ["wolf", "wolf_ashen", "wolf_black", "wolf_chestnut", "wolf_rusty", "wolf_snowy",
              "wolf_spotted", "wolf_striped", "wolf_woods"]


def wolf_specs():
    out = {}
    w, h = 64, 32
    part = np.full((h, w), "fur", dtype=object)
    paint(part, W_HEAD, "head")
    paint(part, W_SNOUT, "snout")
    paint(part, W_EARS, "ear")
    paint(part, W_RUFF, "ruff")
    paint(part, W_TAIL, "tail")
    paint(part, W_PADS, "pad")
    for coat in WOLF_COATS:
        wild = lib.load_source("mobs_mc_" + coat, GAME)
        for face in ("", "_angry", "_tame"):
            stem = "mobs_mc_" + coat + face
            src = lib.load_source(stem, GAME)
            drawn = src[..., 3] >= 0.5
            mat = np.where(part == "head", "fur", part).astype(object)
            # The eyes: the newer coats draw an iris and a pupil each, the
            # pale wolf a single pupil.
            eyes = [(5, 6), (8, 6)] if coat == "wolf" else [(4, 6), (5, 6), (8, 6), (9, 6)]
            for x, y in eyes:
                mat[y, x] = "eye"
            for x, y in W_NOSE:
                mat[y, x] = "nose"
            diff = np.abs(src - wild).max(-1) > 1e-3
            for y, x in zip(*np.nonzero(diff & drawn)):
                if part[y, x] == "snout":
                    # An angry pale wolf bares its teeth.
                    mat[y, x] = "teeth" if lum(src[y, x, :3]) > 0.5 else "throat"
                elif face == "_tame" and part[y, x] == "ruff":
                    # The pale wolf's tame art draws its collar in.
                    mat[y, x] = "collar"
            out[stem] = to_spec(mat, {"fur": PET_FUR, "ruff": LONG_FUR, "snout": SNOUT,
                                      "nose": NOSE, "eye": EYE, "ear": EAR, "tail": PET_TAIL,
                                      "pad": PAD,
                                      "teeth": TEETH, "throat": THROAT, "collar": COLLAR},
                                src=src)
    src = lib.load_source("mobs_mc_wolf_collar", GAME)
    out["mobs_mc_wolf_collar"] = to_spec(np.full((h, w), "collar", dtype=object),
                                         {"collar": COLLAR}, {"overlay": True, "surface": 0.81}, src)
    return out


# --- cats -----------------------------------------------------------------------
# mobs_mc_cat.b3d, one brush. The ocelot draws mobs_mc_cat_ocelot on it too.

C_NOSEBOX = [(2, 24, 5, 26), (5, 24, 8, 26), (0, 26, 2, 28), (2, 26, 5, 28), (5, 26, 7, 28),
             (7, 26, 10, 28)]
C_EARS = [(2, 10, 3, 12), (3, 10, 4, 12), (8, 10, 9, 12), (9, 10, 10, 12), (0, 12, 12, 13)]
C_TAIL = [(1, 15, 2, 16), (2, 15, 3, 16), (5, 15, 6, 16), (6, 15, 7, 16), (0, 16, 8, 24)]
C_PADS = [(12, 13, 14, 15), (44, 0, 46, 2)]
C_EYES = [(5, 6), (9, 6)]
C_NOSE = [(3, 26)]
CAT_COATS = ["all_black", "black", "british_shorthair", "calico", "jellie", "ocelot", "persian",
             "ragdoll", "red", "siamese", "tabby", "white"]


def cat_specs():
    out = {}
    w, h = 64, 32
    part = np.full((h, w), "fur", dtype=object)
    paint(part, C_NOSEBOX, "snout")
    paint(part, C_EARS, "ear")
    paint(part, C_TAIL, "tail")
    paint(part, C_PADS, "pad")
    for x, y in C_EYES:
        part[y, x] = "eye"
    for x, y in C_NOSE:
        part[y, x] = "nose"
    for coat in CAT_COATS:
        stem = "mobs_mc_cat_" + coat
        src = lib.load_source(stem, GAME)
        out[stem] = to_spec(part.copy(), {"fur": PET_FUR, "snout": SNOUT, "nose": NOSE,
                                          "eye": EYE, "ear": EAR, "tail": PET_TAIL, "pad": PAD},
                            src=src)
    src = lib.load_source("mobs_mc_cat_collar", GAME)
    out["mobs_mc_cat_collar"] = to_spec(np.full((h, w), "collar", dtype=object),
                                        {"collar": COLLAR}, {"overlay": True, "surface": 0.81}, src)
    return out


FAMILIES = {"horse": horse_specs, "llama": llama_specs, "wolf": wolf_specs, "cat": cat_specs}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check_only = "--check" in sys.argv
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
    main()
