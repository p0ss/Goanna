"""Texel extrusion: the authored look, one rule for every stem.

The relief follows the art's own texel grid. Every source texel is a flat
plateau with a one pixel chamfer, and nothing finer: no noise, no grain
inside a texel, no rounded or warped outlines. The earlier authored sets
reached for high definition surface detail, which reads out of place in a
blocky world; this keeps the pixel art and makes it crisp.

A texture is one or more materials. Inside a material the height comes
from one of four modes:

  shade  lighter is higher. A coarse level (a few quantised bands, so
         similar neighbours merge into sub-blocks) plus a finer step from
         each texel's exact shade, the detail harmonic, so panels of
         different lightness never sit at one height. Texels much darker
         than the material (plank gaps, cracks) sink as joints unless the
         material says joints: false. Natural surfaces.
  parts  every connected piece of the material is one solid height, and
         pieces differ by their mean shade. Books on a shelf. A detail
         share keeps a little of each texel's shade inside its piece
         (stone bricks).
  flat   the whole material is one height. A frame's beams.
  soft   skin. Lighter is a little higher, in proportion to the shade
         (with a small share of each texel's rank, "detail", default
         0.25) over a small "span" (default 0.06) centred on "base" (or,
         with "anchor": "top", topped at it), no joints. atlas.py adds the rest of the treatment: wider, rounded
         steps between its own shades and a low dome over each piece
         (atlas.soft_surface).

Which texel belongs to which material comes from, in order: the spec's
grid (one character per texel, legend maps each character to a material
and optionally a fixed height), then its palette map (hex colour to
material), then the first material. Stems with no spec are one shade
material of their class.

Specs live in tools/pbr_author/specs/<game>/<stem>.json, one file per
stem so authors working in parallel never edit the same file:

  {
    "materials": {
      "stone": {"mode": "shade", "base": 0.25, "span": 0.5, "joints": false},
      "coal":  {"mode": "shade", "base": 0.85, "span": 0.15, "detail": 0.2}
    },
    "palette": {"#1d1d1d": "coal"},
    "grid": ["FFFF...", ...],            optional, one string per row
    "legend": {"F": "frame", "a": {"material": "book", "h": 0.6}},
    "class": "wood",                     optional class override
    "strength": 16,                      optional normal strength
    "chamfer": 3                         optional bevel width in map pixels
  }

Material keys besides mode, base and span: detail (share of the span the
per texel step takes, default 0.35), levels, joints, joint (how deep a
joint sinks under the material's base, as a share of it), smooth
(absolute smoothness 0..1, default the class level), smooth_spread,
f0 (dielectric reflectance, diamond 0.17), metal (true for metal
texels), emission (0..1 glow), emission_shade (glow follows the
shade, lighter texels brighter), micro (on a flat material, the per
texel step, default 0.06; as a string, the material's own micro surface
kind, see material_micro), sss (the _s blue byte for the material in
place of the class's; a top level "sss" sets it for the whole stem),
flush (stand each piece at the height of the material round it, see
flush_features), merge (on a shade material, neighbouring close shades
become one plateau before the levels are taken, see merge_plateaus).

A spec's "rects", [[material, x0, y0, x1, y1], ...] in texels, end
exclusive, gives the texels inside each rectangle that material over the
palette and the grid, so a variant can mark an ear hole or a nose
without repeating the whole grid.

Mob skins are model atlases, not tiles, and atlas.py builds them with
this rule and these specs (stems/<game>.mobs.txt).
"""
import json
import os
import sys
import zlib
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402

SPECS = Path(__file__).resolve().parent / "specs"
HERE_STEMS = Path(__file__).resolve().parent / "stems"

# Per class: coarse levels, joint depth, normal strength (texels of the
# 256 px map for the full 0..1 height; 25.6 is the client's 0.10 node
# parallax cap), smoothness spread.
CLASS_STYLE = {
    "stone": (4, 0.55, 22, 0.10),
    "cobble": (4, 0.60, 22, 0.10),
    "gravel": (4, 0.40, 20, 0.10),
    "wood": (3, 0.70, 16, 0.08),
    "planks": (3, 0.70, 16, 0.08),
    "dirt": (3, 0.40, 16, 0.08),
    "sand": (3, 0.30, 10, 0.06),
    "leaves": (3, 0.50, 14, 0.08),
    # Soil is dirt's style. Cloth, snow, ice and glass are soft or smooth
    # and shallow; metal is worked flat with crisp detail. These fell back
    # to stone's depth before, which made wool and snow as deep as rock.
    "soil": (3, 0.40, 16, 0.08),
    # Cloth is shallow on purpose: nodes_array.gdshader gives class cloth
    # a rim term read from the normal map, so every steep chamfer on wool
    # lit up as a neon outline. At this strength the steps still shade
    # but the rim stays on the block's own silhouette.
    "cloth": (3, 0.30, 2, 0.05),
    "snow": (3, 0.20, 8, 0.05),
    "ice": (3, 0.30, 8, 0.04),
    "glass": (2, 0.30, 10, 0.02),
    "metal": (3, 0.50, 18, 0.06),
}
DEFAULT_STYLE = CLASS_STYLE["stone"]
DETAIL = 0.35
# A soft material's height range and its detail harmonic (see heights).
SOFT_SPAN = 0.06
SOFT_DETAIL = 0.25
# Height range of a flat material's per texel micro texture (see heights).
MICRO = 0.06
# The material a stem with no spec gets, where the plain shaded rule is
# wrong for the whole class. Wool's art is fine fibre noise over a few
# shades; quantised into levels with joints it read as a circuit board, so
# cloth is a soft felt: a narrow range, two levels, no joints.
CLASS_MATERIAL = {
    "cloth": {"mode": "shade", "base": 0.4, "span": 0.25, "levels": 2,
              "detail": 0.5, "joints": False},
}
# Smoothness levels that differ from the bake's class table. The bake's
# metal level (0.40) is cast iron; a block of steel or gold read dull
# beside the extruded relief, so authored metal is polished unless a spec
# says otherwise (weathered copper, a rusty anvil).
CLASS_SMOOTH = {"metal": 0.78}


def load_spec(stem, game=lib.DEFAULT_GAME):
    p = SPECS / game / (stem + ".json")
    spec = json.loads(p.read_text()) if p.exists() else {}
    return variant_spec(spec, os.environ.get("GOANNA_PBR_VARIANT", ""))


def variant_spec(spec, name):
    """spec with its "variants"[name] laid over it, or spec as it is when
    it has no such variant. A variant's own keys replace the spec's, except
    "materials", whose entries are laid over the spec's material of the
    same name key by key, a null value removing that key. This keeps an
    earlier treatment reachable for comparison: the player's hair keeps
    "old", the authored strand maps from before the client drew hair's
    strands, and "round1", the first maps made for the shader
    (GOANNA_PBR_VARIANT=old, docs/materials.md)."""
    var = (spec.get("variants") or {}).get(name) if name else None
    spec = {k: v for k, v in spec.items() if k != "variants"}
    if not var:
        return spec
    mats = {k: dict(m) for k, m in (spec.get("materials") or {}).items()}
    for k, v in var.items():
        if k != "materials":
            spec[k] = v
    for mname, over in (var.get("materials") or {}).items():
        m = mats.setdefault(mname, {})
        for k, v in over.items():
            if v is None:
                m.pop(k, None)
            else:
                m[k] = v
    spec["materials"] = mats
    return spec


def _rank01(v):
    """Each value's rank among v, 0..1; equal shades share a rank."""
    u, inv = np.unique(np.round(v, 4), return_inverse=True)
    r = np.arange(len(u), dtype=np.float32) / max(len(u) - 1, 1)
    return r[inv]


def _micro(v, sel):
    """0..1 per texel for a flat material: the rank of its shade where the
    art has more than two, else a fixed hash of the texel's position, so
    one colour concrete and a glass pane still vary texel to texel."""
    if len(np.unique(np.round(v, 4))) > 2:
        return _rank01(v)
    ys, xs = np.nonzero(sel)
    h = np.sin(xs * 12.9898 + ys * 78.233) * 43758.5453
    return (h - np.floor(h)).astype(np.float32)


def _levels(v, levels):
    """Rank based bands, so each level holds a similar share of texels."""
    edges = np.quantile(v, np.linspace(0, 1, levels + 1)[1:-1])
    return np.digitize(v, edges).astype(np.float32) / max(levels - 1, 1)


def _components(mask):
    """Wrapped 4 connected components of a boolean 16 px mask."""
    h, w = mask.shape
    lab = -np.ones(mask.shape, dtype=int)
    n = 0
    for y in range(h):
        for x in range(w):
            if not mask[y, x] or lab[y, x] >= 0:
                continue
            stack = [(y, x)]
            lab[y, x] = n
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = (cy + dy) % h, (cx + dx) % w
                    if mask[ny, nx] and lab[ny, nx] < 0:
                        lab[ny, nx] = n
                        stack.append((ny, nx))
            n += 1
    return lab, n


def _hex(rgb):
    c = np.clip(np.round(rgb * 255.0), 0, 255).astype(int)
    return "#%02x%02x%02x" % tuple(c)


def assign(src, spec):
    """Per texel material name and fixed height (nan where none), plus a
    part id map for characters of the grid (each character one part)."""
    h, w = src.shape[:2]
    names = list(spec.get("materials", {}).keys()) or ["base"]
    mat = np.full((h, w), names[0], dtype=object)
    fixed = np.full((h, w), np.nan, dtype=np.float32)
    part = -np.ones((h, w), dtype=int)
    pal = {k.lower(): v for k, v in spec.get("palette", {}).items()}
    if pal:
        for y in range(h):
            for x in range(w):
                m = pal.get(_hex(src[y, x, :3]))
                if m:
                    mat[y, x] = m
    grid = spec.get("grid")
    if grid:
        if len(grid) != h or any(len(r) != w for r in grid):
            raise ValueError("grid must be %d rows of %d characters" % (h, w))
        legend = spec.get("legend", {})
        chars = sorted({c for r in grid for c in r})
        for y in range(h):
            for x in range(w):
                c = grid[y][x]
                e = legend.get(c)
                if e is None:
                    continue
                if isinstance(e, str):
                    e = {"material": e}
                mat[y, x] = e["material"]
                if "h" in e:
                    fixed[y, x] = e["h"]
                part[y, x] = chars.index(c)
    # "rects": [[material, x0, y0, x1, y1], ...], end exclusive, laid
    # over the palette and the grid: a few texels a variant gives a
    # material of their own (an ear hole, a nose) without repeating the
    # whole grid.
    for r in spec.get("rects", []):
        mat[r[2]:r[4], r[1]:r[3]] = r[0]
    unknown = set(mat.ravel()) - set(names)
    if unknown:
        raise ValueError("materials not declared: %s" % sorted(unknown))
    return mat, fixed, part


def heights(src, spec, cls, soft=True):
    """The 16 px height field (0..1), a 0..1 shade position for the
    smoothness, the joint mask and the material map. soft=False stands
    every soft material flat at its base."""
    levels_c, joint_c, _, _ = CLASS_STYLE.get(cls, DEFAULT_STYLE)
    mats = spec.get("materials") or {"base": CLASS_MATERIAL.get(cls, {"mode": "shade"})}
    alpha = src[..., 3] if src.shape[-1] == 4 else np.ones(src.shape[:2], np.float32)
    drawn = alpha >= 0.5
    lum = lib.luminance(src[..., :3])
    mat, fixed, part = assign(src, spec)
    hgt = np.zeros(lum.shape, np.float32)
    pos = np.full(lum.shape, 0.5, np.float32)
    joints = np.zeros(lum.shape, bool)
    for name, m in mats.items():
        sel = drawn & (mat == name)
        if not sel.any():
            continue
        mode = m.get("mode", "shade")
        base = float(m.get("base", 0.35))
        span = float(m.get("span", 0.65))
        v = lum[sel]
        if mode == "flat":
            t = np.full(v.shape, 0.5, np.float32)
            # Micro texture: a perfectly flat face read worse than the bake's
            # soft noise (owner, 2026-09-26), so a flat material still steps
            # a little per texel: by its own shades where it has several,
            # by a fixed per texel pattern where the art is one colour. On
            # the texel grid, never inside a texel. "micro": 0 turns it off.
            # A string "micro" names the material's micro surface kind
            # (atlas.py, micro.py) instead; the per texel step is then
            # "step", default none, so a piece stays one height.
            micro = m.get("micro", MICRO)
            micro = float(m.get("step", 0.0)) if isinstance(micro, str) else float(micro)
            centre = base + 0.5 * span
            if micro > 0:
                t = _micro(v, sel)
            base, span = centre - 0.5 * micro, micro
        elif mode == "parts":
            # A grid part is its character; otherwise a connected piece.
            lab = np.where(part >= 0, part, -1)
            if not (lab[sel] >= 0).all():
                cl, _ = _components(sel)
                lab = np.where(lab >= 0, lab, 1000 + cl)
            t_map = np.zeros(lum.shape, np.float32)
            ids = np.unique(lab[sel])
            means = np.array([lum[sel & (lab == i)].mean() for i in ids])
            r = _rank01(means) if len(ids) > 1 else np.full(1, 0.5)
            for i, ri in zip(ids, r):
                t_map[sel & (lab == i)] = ri
            t = t_map[sel]
            # detail: a share of the span for each texel's own shade inside
            # its piece, so a stone brick is one block with a little face
            # texture rather than a flat tile. Default 0, a solid piece.
            pd = float(m.get("detail", 0.0))
            if pd > 0:
                t = (1.0 - pd) * t + pd * _rank01(v)
        elif mode == "soft":
            # Skin. Lighter is a little higher, as in shade, but in
            # proportion to the shade rather than by bands: two near equal
            # shades of a face stand at near equal heights, so the art's
            # shading reads as gentle form and never as tiles. The detail
            # harmonic (each texel's rank) is a small share. No joints.
            # The range is centred on base, so the skin's mean stays where
            # a flat piece of it stood and the features keep their places
            # above and below it. With soft=False (a neighbouring part's
            # view of this one, atlas.stack_fields) the material is flat at
            # base: the steps are this part's own surface.
            # "anchor": "top" puts the lightest shade at base and the rest
            # below it, so parts laid over the skin at base (a player's
            # eyes) stay flush with the light skin round them however
            # wide the span, and soft=False reads the skin at that height.
            span = float(m.get("span", SOFT_SPAN))
            anchor = 1.0 if m.get("anchor") == "top" else 0.5
            base -= anchor * span
            lo, hi = np.percentile(v, 5), np.percentile(v, 95)
            if soft and hi - lo > 1e-4:
                lin = np.clip((v - lo) / max(hi - lo, 1e-4), 0.0, 1.0)
                sd = float(m.get("detail", SOFT_DETAIL))
                t = ((1.0 - sd) * lin + sd * _rank01(v)).astype(np.float32)
            else:
                # Flat, or one shade: the middle of the range (its top
                # when anchored there).
                t = np.full(v.shape, anchor, np.float32)
        else:
            detail = float(m.get("detail", DETAIL))
            lv = int(m.get("levels", levels_c))
            if m.get("merge"):
                # Plateaus follow the art's shading regions, not its
                # texels: neighbouring close shades become one piece at
                # one shade (merge_plateaus) before the levels are taken.
                v = merge_plateaus(lum, sel, float(m["merge"]))[sel]
            t = (1.0 - detail) * _levels(v, lv) + detail * _rank01(v)
        hv = base + span * t
        pos[sel] = t
        if mode == "shade" and m.get("joints", True):
            d = v < np.quantile(v, 0.5) - 1.5 * np.std(v)
            hv = np.where(d, base * (1.0 - float(m.get("joint", joint_c))), hv)
            jm = np.zeros(lum.shape, bool)
            jm[sel] = d
            joints |= jm
        hgt[sel] = hv
    if any(m.get("flush") for m in mats.values()):
        hgt = flush_features(hgt, mat, drawn, mats)
    f = ~np.isnan(fixed) & drawn
    hgt[f] = fixed[f]
    hgt[~drawn] = 0.0
    return np.clip(hgt, 0.0, 1.0), pos, joints, mat


def merge_plateaus(lum, sel, share):
    """lum with every texel of sel replaced by the mean shade of its
    plateau: neighbouring runs of close shades merged into one piece, so
    a shade material's levels step between the art's shading regions (a
    cheekbone, the shadow under it, a forehead) instead of between single
    texels, which on a face read as a checkerboard of coloured squares.

    Each 4 connected run of one shade (to a byte) starts as a piece. The
    two neighbouring pieces whose mean shades are closest merge first, as
    long as the merged piece's shades span at most share of the shades
    sel spans, the rule the player's dark hair styles were merged by. It
    stops when no neighbouring pair is close enough. Not wrapped: on a
    model atlas a wrap would join faces that are not neighbours. Faces
    side by side in the atlas can merge, which on the usual layouts joins
    faces that meet at a box edge on the model too."""
    from scipy import ndimage
    v = lum[sel]
    limit = share * float(v.max() - v.min()) if v.size else 0.0
    q = np.round(lum * 255.0).astype(np.int64)
    lab = -np.ones(lum.shape, np.int64)
    n = 0
    for val in np.unique(q[sel]):
        cl, k = ndimage.label(sel & (q == val))
        lab = np.where(cl > 0, cl - 1 + n, lab)
        n += k
    parent = list(range(n))
    lo = np.full(n, np.inf)
    hi = np.full(n, -np.inf)
    tot = np.zeros(n)
    cnt = np.zeros(n)
    ys, xs = np.nonzero(sel)
    ids = lab[ys, xs]
    np.minimum.at(lo, ids, lum[ys, xs])
    np.maximum.at(hi, ids, lum[ys, xs])
    np.add.at(tot, ids, lum[ys, xs])
    np.add.at(cnt, ids, 1.0)
    pairs = set()
    for a, b in ((lab[:, :-1], lab[:, 1:]), (lab[:-1, :], lab[1:, :])):
        ok = (a >= 0) & (b >= 0) & (a != b)
        for i, j in zip(a[ok], b[ok]):
            pairs.add((min(i, j), max(i, j)))

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    while True:
        best = None
        live = set()
        for i, j in pairs:
            i, j = root(i), root(j)
            if i == j:
                continue
            i, j = min(i, j), max(i, j)
            live.add((i, j))
            if max(hi[i], hi[j]) - min(lo[i], lo[j]) > limit + 1e-9:
                continue
            d = abs(tot[i] / cnt[i] - tot[j] / cnt[j])
            if best is None or d < best[0]:
                best = (d, i, j)
        pairs = live
        if best is None:
            break
        _, i, j = best
        parent[j] = i
        lo[i], hi[i] = min(lo[i], lo[j]), max(hi[i], hi[j])
        tot[i] += tot[j]
        cnt[i] += cnt[j]
    out = lum.copy()
    roots = np.array([root(i) for i in range(n)], np.int64)
    r = roots[ids]
    out[ys, xs] = tot[r] / cnt[r]
    return out


def flush_features(hgt, mat, drawn, mats):
    """hgt with every material that names "flush" set to the height of
    the material it sits in, plus an offset: a face's eyes, brows and
    mouth stand relative to the skin round them rather than at a fixed
    height, so a sculpted skin (a wide "span") does not leave an eye
    proud of a sunk socket or sunk under a raised cheek.

      "flush": {"to": ["skin"], "offset": 0.0, "group": "eye"}

    Each 4 connected piece of the group (every material naming the same
    "group", by default the material alone, so an eye's white and iris
    are one piece) takes the mean height of the "to" texels 4 adjacent to
    it, each of its materials adding its own "offset" (a share of the
    height range). A piece with no such neighbour keeps its base. Pieces
    are found without wrapping: on a skin atlas a wrap would join faces
    that are not neighbours on the model."""
    from scipy import ndimage
    groups = {}
    for name, m in mats.items():
        fl = m.get("flush")
        if fl:
            groups.setdefault(fl.get("group", name), []).append((name, fl))
    out = hgt.copy()
    for members in groups.values():
        names = [n for n, _ in members]
        to = sorted({t for _, fl in members for t in fl.get("to", [])})
        sel = drawn & np.isin(mat, names)
        lab, n = ndimage.label(sel)
        ref = drawn & np.isin(mat, to)
        for k in range(1, n + 1):
            piece = lab == k
            ring = ndimage.binary_dilation(piece) & ~piece & ref
            if not ring.any():
                continue
            level = float(hgt[ring].mean())
            for name, fl in members:
                own = piece & (mat == name)
                out[own] = level + float(fl.get("offset", 0.0))
    return out


_frozen = {}


def stem_class(stem, game):
    """The class a stem was authored under, from stems/<game>.classes.json.
    lib.class_of infers it from the installed pack's _s bytes, and once the
    pack is the authored one that reads back this tool's own smoothness:
    stone came back as gravel and rebuilt differently. The file freezes the
    classes the reviewed pack was built with; a stem missing from it falls
    back to the inference."""
    if game not in _frozen:
        p = HERE_STEMS / (game + ".classes.json")
        _frozen[game] = json.loads(p.read_text()) if p.exists() else {}
    return _frozen[game].get(stem) or lib.class_of(stem, game)


def chamfer_px(spec, cell):
    """The bevel width in map pixels: the spec's (default 1), but never
    more than a quarter of a texel, so a 128 px atlas (the lectern, texels
    two pixels wide) keeps flat tops at all. A spec's width is in 256 px
    map pixels and scales with the map, but a chamfer stays at least one
    pixel: at 128 the default would otherwise round to none and every step
    would be a cliff."""
    return min(lib.px(spec.get("chamfer", 1)), cell // 4)


def chamfer(h, px=1):
    """A px wide bevel on every step (wrapped box blur), nothing more."""
    out = h.copy()
    for _ in range(px):
        acc = np.zeros_like(out)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                acc += np.roll(out, (dy, dx), axis=(0, 1))
        out = acc / 9.0
    return out


def surface(spec, cls, mat, pos, joints):
    """Per texel smoothness, F0, metal flag and glow at the art's size,
    from each material's keys and the class defaults."""
    _, _, _, spread = CLASS_STYLE.get(cls, DEFAULT_STYLE)
    level, _, is_metal = lib.class_spec(cls)
    mats = spec.get("materials") or {"base": CLASS_MATERIAL.get(cls, {})}
    sm = np.zeros(mat.shape, np.float32)
    f0 = np.full(mat.shape, lib.DIELECTRIC_F0 / 255.0, np.float32)
    metal = np.full(mat.shape, bool(is_metal))
    glow = np.zeros(mat.shape, np.float32)
    for name, m in mats.items():
        sel = mat == name
        s0 = float(m.get("smooth", CLASS_SMOOTH.get(cls, level)))
        sp = float(m.get("smooth_spread", spread))
        # Raised faces a touch smoother (worn), no noise.
        sm[sel] = s0 + sp * (pos[sel] - 0.5)
        if "f0" in m:
            f0[sel] = float(m["f0"])
        if "metal" in m:
            metal[sel] = bool(m["metal"])
        g = float(m.get("emission", 0.0))
        # emission_shade: the lighter texels glow and the darker ones less,
        # so a glowing block keeps its pattern instead of washing to flat.
        glow[sel] = g * pos[sel] ** 2 if m.get("emission_shade") else g
    sm[joints] -= spread
    return sm, f0, metal, glow


def micro_kind(stem, spec, cls):
    """Which micro surface a stem gets: spec "micro" names the kind
    ("concrete", "none", ...); otherwise the class decides."""
    kind = spec.get("micro", CLASS_MICRO.get(cls))
    if kind is None and "concrete" in stem and "powder" not in stem:
        kind = "concrete"
    # Names say more than the class does: a log's side is bark, not planks,
    # and a tool block or anvil is worn metal, not a brushed plate.
    if "micro" not in spec:
        name = stem.lower()
        if kind == "wood" and not name.endswith("_top") and (
                name.endswith("tree") or name.endswith("_log") or "log_" in name
                or "hyphae" in name or "_stem" in name):
            kind = "bark"
        if kind == "metal" and any(w in name for w in ("anvil", "hopper", "cauldron", "rail",
                                                        "chain", "bars", "door", "trapdoor")):
            kind = "metal_worn"
    return kind


def own_micro(spec):
    """The materials that name their own micro kind ("none" among them)."""
    return [k for k, m in (spec.get("materials") or {}).items()
            if isinstance(m.get("micro"), str)]


def _micro_dir(how, sel, iy, ix):
    """Per map pixel of a material, the direction its micro runs, (dx, dy)
    in the image: "h" right, "v" down, a number an angle in degrees (0
    right, 90 down), "along" the long axis of each 4 connected piece of
    the material (a tool's handle drawn as a diagonal staircase), from the
    piece's texel covariance as on a skin (atlas._piece_frames). A piece
    too small or too round to have a long axis runs right. Also returns
    the pieces' frames (centre and half size, texels) for the kinds that
    read them."""
    import atlas
    right = np.array((1.0, 0.0))
    cx, cy, hx, hy, ax = atlas._piece_frames(sel, np.zeros(sel.shape, int), lambda i: right)
    k = len(ix)
    if how == "along":
        dvec = ax[iy, ix, 0].astype(np.float64), ax[iy, ix, 1].astype(np.float64)
    elif how == "v":
        dvec = np.zeros(k), np.ones(k)
    elif isinstance(how, (int, float)):
        a = np.radians(float(how))
        dvec = np.full(k, np.cos(a)), np.full(k, np.sin(a))
    elif how == "h":
        dvec = np.ones(k), np.zeros(k)
    else:
        raise ValueError("micro_dir %r: a tile takes h, v, along or an angle" % (how,))
    return dvec, (cx, cy, hx, hy)


def material_micro_px(stem, spec, cls, mat, src, n):
    """material_micro at this build's resolution: at 128 drawn at
    lib.SUPERSAMPLE times the texel, the 256 build's own, averaged down and
    its detail faded by lib.MICRO_FADE, as micro_field_px does for the
    stem's kind. At 256 and 512 it is material_micro itself."""
    f = lib.SUPERSAMPLE
    if f == 1:
        return material_micro(stem, spec, cls, mat, src, n)
    d, s = material_micro(stem, spec, cls, mat, src, n * f)
    return lib.downsample(d, f) * np.float32(lib.MICRO_FADE), lib.downsample(s, f)


def material_micro(stem, spec, cls, mat, src, n):
    """(detail, smooth swing) at the map's size for the materials of a tile
    that name their own micro kind, the rest zero.

    One micro kind for the whole stem was wrong wherever a stem mixes
    materials: a hand tool's wooden handle carried the head's brushed metal
    and no grain. A material may name its own kind, as on a skin:

      "handle": {"mode": "shade", ..., "micro": "wood", "micro_dir": "along"}

    The kind is any of micro.py's (wood, bark, glass, metal and metal_worn
    read this module's block fields at one block texel per art texel and
    at the block's rise, so a handle's grain is the planks' grain) or any
    of MICRO_KINDS, the block field laid along the direction. "none" is no
    micro at all. Keys: "micro_strength" (on the amplitude), "micro_swing"
    (on the smoothness swing), "micro_params" (micro.py's), "micro_dir"
    (_micro_dir; default the stem's "micro_dir", else "h", as the stem's
    own micro). The kinds that need a skin's locks (micro.LOCK_KINDS,
    SLOPE_KINDS) are atlas.py's only. Coordinates are in art texels, so on
    a tile drawn at 32 px a texel of grain is half a planks texel."""
    import micro
    rows, cols = mat.shape
    H, W = rows * n, cols * n
    up = lambda a: np.kron(a, np.ones((n, n), dtype=a.dtype))  # noqa: E731
    alpha = src[..., 3] if src.shape[-1] == 4 else np.ones(mat.shape, np.float32)
    drawn = alpha >= 0.5
    xs = (np.arange(W) + 0.5) / n
    ys = (np.arange(H) + 0.5) / n
    detail = np.zeros((H, W), np.float32)
    swing_out = np.zeros((H, W), np.float32)
    strength = float(spec.get("strength", CLASS_STYLE.get(cls, DEFAULT_STYLE)[2]))
    for name, m in (spec.get("materials") or {}).items():
        kind = m.get("micro")
        if not isinstance(kind, str) or kind == "none":
            continue
        sel = drawn & (mat == name)
        if not sel.any():
            continue
        iy, ix = np.nonzero(up(sel))
        ty, tx = iy // n, ix // n
        (dx, dy), (cx, cy, hx, hy) = _micro_dir(m.get("micro_dir", spec.get("micro_dir", "h")),
                                                sel, ty, tx)
        x, y = xs[ix], ys[iy]
        u = x * dx + y * dy
        v = -x * dy + y * dx
        seed = zlib.crc32((stem + "/" + name).encode()) & 0xffff
        if kind in micro.LOCK_KINDS or kind in micro.SLOPE_KINDS:
            raise ValueError("micro %r needs a skin's locks; atlas.py only" % kind)
        if kind in micro.KINDS or kind in micro.PRESETS:
            ctx = {"x": x, "y": y, "u": u, "v": v, "seed": seed, "cell": n,
                   "strength": strength,
                   "px": (x - cx[ty, tx]) / hx[ty, tx], "py": (y - cy[ty, tx]) / hy[ty, tx],
                   "hx": hx[ty, tx], "hy": hy[ty, tx]}
            d, s, amp, swing = micro.evaluate(kind, ctx, m.get("micro_params"))
        elif kind in MICRO_KINDS:
            amp, swing = MICRO_KINDS[kind]
            fd, fs = micro_field(kind, seed, size=n * 16)
            d = _sample(fd, v * n - 0.5, u * n - 0.5)
            s = _sample(fs, v * n - 0.5, u * n - 0.5)
        else:
            raise ValueError("unknown micro kind %r on material %s" % (kind, name))
        detail[iy, ix] += amp * float(m.get("micro_strength", 1.0)) * d
        swing_out[iy, ix] += swing * float(m.get("micro_swing", 1.0)) * s
    return detail, swing_out


def build(stem, out_dir, game=lib.DEFAULT_GAME, spec=None, preview=True):
    """Write the stem's three maps to out_dir and return lib's metrics."""
    spec = load_spec(stem, game) if spec is None else spec
    cls = spec.get("class") or stem_class(stem, game)
    _, _, strength, spread = CLASS_STYLE.get(cls, DEFAULT_STYLE)
    # Strength is in 256 px map pixels; the same slope at 512 is twice
    # as many pixels of rise.
    strength = float(spec.get("strength", strength)) * lib.PX
    src = lib.load_source(stem, game)
    # The map is SIZE wide with square texels, so a vertical animation strip
    # (16 x 64, four frames) comes out 256 x 1024 and the client cuts the
    # same frame from it as from the colour (docs/node-animation.md), and a
    # model atlas (a 64 x 32 sign) comes out 256 x 128. Levels are taken
    # over the whole strip, so every frame of an animation shares them.
    if lib.SIZE % src.shape[1]:
        raise ValueError("%s is %d wide, which does not divide %d"
                         % (stem, src.shape[1], lib.SIZE))
    hgt, pos, joints, mat = heights(src, spec, cls)
    n = lib.SIZE // src.shape[1]
    up = lambda a: np.kron(a, np.ones((n, n), dtype=a.dtype))  # noqa: E731
    # A wider chamfer rounds a thin cut-out piece (a rail, a ladder rung)
    # so its edges catch the light; parallax cannot lift a cut-out's edge.
    hi = chamfer(up(hgt), chamfer_px(spec, n))

    sm, f0, metal, glow = surface(spec, cls, mat, pos, joints)
    emission = up(glow) if glow.max() > 0 else None
    kind = micro_kind(stem, spec, cls)
    detail = None
    smooth_hi = np.clip(up(sm), 0.0, lib.SMOOTH_CEILING)
    # A material naming its own micro kind takes none of the stem's.
    own = own_micro(spec)
    keep = up((~np.isin(mat, own)).astype(np.float32)) if own else 1.0
    if kind in MICRO_KINDS:
        amp, swing = MICRO_KINDS[kind]
        amp *= float(spec.get("micro_strength", 1.0))
        d, dsm = micro_field_px(kind, zlib.crc32(stem.encode()) & 0xffff,
                                direction=spec.get("micro_dir", "h"))
        detail = amp * _fit(d, hi.shape) * keep
        smooth_hi = np.clip(smooth_hi + swing * _fit(dsm, hi.shape) * keep, 0.0,
                            lib.SMOOTH_CEILING)
    if own:
        d2, s2 = material_micro_px(stem, spec, cls, mat, src, n)
        detail = d2 if detail is None else detail + d2
        smooth_hi = np.clip(smooth_hi + s2, 0.0, lib.SMOOTH_CEILING)
    sss = sss_map(spec, cls, mat, n)
    albedo = np.kron(src, np.ones((n, n, 1), dtype=src.dtype))
    return lib.pack(stem, out_dir, albedo, hi, smooth_hi, cls,
                    normal_strength=strength, metal_mask=up(metal), keep_mean=False,
                    emission=emission, f0=up(f0), fine_detail=1.0,
                    art_texels=src.shape[1], normal_detail=detail, sss=sss)


def sss_map(spec, cls, mat, n):
    """The _s blue byte per pixel where the spec or a material sets "sss"
    (0 to 255, LabPBR: porosity up to 64, subsurface scattering above),
    else None and the class's one value. Every plant took class leaves'
    160, so a mushroom glowed through like a thin leaf when lit from
    behind (2026-10-02)."""
    mats = spec.get("materials") or {}
    if "sss" not in spec and not any("sss" in m for m in mats.values()):
        return None
    out = np.full(mat.shape, float(spec.get("sss", lib.sss_byte(cls))), np.float32)
    for name, m in mats.items():
        if "sss" in m:
            out[mat == name] = float(m["sss"])
    return np.kron(out, np.ones((n, n), np.float32))


# --- micro surface ------------------------------------------------------------
# The extrusion gives every texel a flat top, and on its own a world of flat
# tops read as plastic (owner, 2026-09-26): the bake's blur had carried pores,
# grain and wear, badly, and the extrusion dropped them with the blur. This
# puts material character back at the map's own resolution, but only into
# the normal and the smoothness: the height the shader's parallax marches
# stays the crisp texel grid, so none of this can soften a step.

def _aniso_noise(size, cells_x, cells_y, seed):
    """Tileable value noise with separate lattice counts per axis, -1..1:
    few cells along x and many along y gives streaks running along x."""
    rng = np.random.default_rng(seed)
    lat = rng.uniform(-1.0, 1.0, (cells_y, cells_x))
    def axis(cells):
        t = (np.arange(size) / size) * cells
        i0 = np.floor(t).astype(int) % cells
        f = t - np.floor(t)
        return i0, (i0 + 1) % cells, f * f * (3 - 2 * f)
    y0, y1, fy = axis(cells_y)
    x0, x1, fx = axis(cells_x)
    fy, fx = fy[:, None], fx[None, :]
    a, b = lat[y0][:, x0], lat[y0][:, x1]
    c, d = lat[y1][:, x0], lat[y1][:, x1]
    return ((a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy).astype(np.float32)


def _pits(size, density, radius, seed):
    """Sparse round dents, 0 flat to -1 at a pit's centre, wrapped. radius
    is in 256 px map pixels and density per 256 px map pixel, so a larger
    map gets the same pits."""
    rng = np.random.default_rng(seed)
    out = np.zeros((size, size), np.float32)
    radius = radius * size / 256.0
    n = int(size * size * density * (256.0 / size) ** 2)
    ys, xs = rng.integers(0, size, n), rng.integers(0, size, n)
    rs = rng.uniform(0.6, 1.0, n) * radius
    r = int(np.ceil(radius))
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            d = np.sqrt(dx * dx + dy * dy)
            depth = np.clip(1.0 - d / rs, 0.0, 1.0)
            np.minimum.at(out, ((ys + dy) % size, (xs + dx) % size), -depth)
    return out


def _scratches(size, count, length, seed, angle=None):
    """Thin straight grooves, 0 flat to -1 in a groove, wrapped. length is
    in 256 px map pixels; a groove stays one pixel wide, so it is finer on
    a larger map."""
    rng = np.random.default_rng(seed)
    length = length * size / 256.0
    out = np.zeros((size, size), np.float32)
    for _ in range(count):
        a = rng.uniform(0, np.pi) if angle is None else angle + rng.normal(0, 0.15)
        y, x = rng.uniform(0, size, 2)
        L = rng.uniform(0.4, 1.0) * length
        t = np.linspace(0, L, int(L * 2) + 2)
        yy = (np.round(y + np.sin(a) * t) % size).astype(int)
        xx = (np.round(x + np.cos(a) * t) % size).astype(int)
        out[yy, xx] = -rng.uniform(0.4, 1.0)
    return out


def _bumps(size, density, radius, seed, flat=0.0):
    """Sparse round rises, 0 flat to 1 at a bump's centre, wrapped. flat
    above 0 gives each a plateau (an aggregate fleck rather than a dome)."""
    return -_pits(size, density, radius, seed) if flat <= 0 else np.clip(
        -_pits(size, density, radius, seed) / max(1e-3, 1.0 - flat), 0.0, 1.0)


def _cracks(size, count, length, seed):
    """Hairline cracks that wander, 0 flat to -1 in a crack, wrapped.
    length is in 256 px map pixels."""
    rng = np.random.default_rng(seed)
    length = length * size / 256.0
    out = np.zeros((size, size), np.float32)
    for _ in range(count):
        y, x = rng.uniform(0, size, 2)
        a = rng.uniform(0, 2 * np.pi)
        for _ in range(int(length)):
            a += rng.normal(0, 0.35)
            y, x = y + np.sin(a), x + np.cos(a)
            out[int(y) % size, int(x) % size] = -rng.uniform(0.6, 1.0)
    return out


def _sample(field, ys, xs):
    """Bilinear, wrapped lookup of field at fractional coordinates."""
    h, w = field.shape
    y0, x0 = np.floor(ys).astype(int), np.floor(xs).astype(int)
    fy, fx = ys - y0, xs - x0
    y0, x0 = y0 % h, x0 % w
    y1, x1 = (y0 + 1) % h, (x0 + 1) % w
    return ((field[y0, x0] * (1 - fx) + field[y0, x1] * fx) * (1 - fy)
            + (field[y1, x0] * (1 - fx) + field[y1, x1] * fx) * fy)


def _wood_grain(size, seed):
    """Grain across a board: thin lines that wave and bunch, a knot or two
    the lines bend round, and pores stretched along the grain. Returns
    (grooves, pores), grooves 0 to -1, pores 0 to -1."""
    rng = np.random.default_rng(seed)
    # Coordinates in 256 px map pixels, so a larger map draws the same grain.
    k = 256.0 / size
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) * k
    # Where each row sits in the grain: a slow wave along the board plus a
    # slower drift, so lines bunch and spread instead of running ruled.
    wave = 6.0 * lib.fbm(size, 3, 2, seed) + 3.0 * _aniso_noise(size, 2, 6, seed + 1)
    v = yy + wave
    # Knots: the grain bends round a small dark eye.
    knot = np.zeros_like(v)
    eye = np.zeros_like(v)
    for _ in range(rng.integers(1, 3)):
        ky, kx = rng.uniform(0, 256.0, 2)
        dy = (yy - ky + 128.0) % 256.0 - 128.0
        dx = (xx - kx + 128.0) % 256.0 - 128.0
        r2 = (dy / 1.0) ** 2 + (dx / 3.0) ** 2
        knot += 9.0 * np.exp(-r2 / 90.0) * np.sign(dy + 1e-3)
        eye = np.minimum(eye, -np.exp(-((dy / 2.2) ** 2 + (dx / 5.0) ** 2)))
    v = v + knot
    # Line spacing varies board to board and across the grain.
    spacing = 3.2 + 1.2 * _aniso_noise(size, 1, 4, seed + 2)
    ph = (v / spacing) % 1.0
    grooves = -np.clip(1.0 - np.abs(ph - 0.5) / 0.14, 0.0, 1.0) ** 1.5
    grooves = np.minimum(grooves * (0.6 + 0.4 * (lib.fbm(size, 4, 2, seed + 3) > -0.2)), eye)
    # Pores: short dashes along the grain.
    dash = _aniso_noise(size, 48, 128, seed + 4)
    pores = -np.clip((dash - 0.62) * 4.0, 0.0, 1.0)
    return grooves.astype(np.float32), pores.astype(np.float32)


# Per material: (normal detail amplitude in height units, smoothness swing).
# Micro surface is mostly smooth with distinct features on it (pores, chips,
# cracks, grain lines, grains), not a noise all over: noise at this
# resolution read as fuzz or sand on everything (owner, 2026-09-26).
MICRO_KINDS = {
    "stone":    (0.045, 0.10),
    "concrete": (0.040, 0.10),
    "soil":     (0.040, 0.05),
    "sand":     (0.035, 0.04),
    "snow":     (0.030, 0.12),
    "wood":     (0.040, 0.08),
    "metal":    (0.010, 0.16),
    "metal_worn": (0.014, 0.18),
    "leaves":   (0.022, 0.10),
    "bark":     (0.045, 0.06),
    "glass":    (0.004, 0.10),
    "cloth":    (0.012, 0.03),
    "ice":      (0.012, 0.10),
}
CLASS_MICRO = {"stone": "stone", "cobble": "stone", "gravel": "soil", "dirt": "soil",
               "soil": "soil", "sand": "sand", "snow": "snow", "wood": "wood",
               "planks": "wood", "metal": "metal", "cloth": "cloth", "ice": "ice",
               "leaves": "leaves", "glass": "glass"}


def micro_field(kind, seed, size=lib.SIZE, direction="h"):
    """(detail, smooth) for one material, each roughly -1..1 at size x size:
    detail goes to the normal, smooth to the smoothness."""
    broad = lambda cells, k: lib.fbm(size, cells, 2, seed + k)  # noqa: E731
    if kind == "stone":
        chips = _pits(size, 0.0009, 2.6, seed + 1)
        marks = _pits(size, 0.0025, 1.2, seed + 2)
        cracks = _cracks(size, 4, 50, seed + 3)
        d = 0.9 * chips + 0.6 * marks + 0.8 * cracks + 0.12 * broad(6, 4)
        sm = 0.7 * broad(5, 5) - 0.6 * (d < -0.3)
    elif kind == "concrete":
        pores = _pits(size, 0.0022, 1.5, seed + 1)
        flecks = _bumps(size, 0.0012, 1.6, seed + 2, flat=0.5)
        d = 1.0 * pores + 0.35 * flecks + 0.08 * broad(4, 3)
        sm = 0.8 * broad(3, 4) - 0.7 * (pores < -0.3)
    elif kind == "soil":
        clods = _bumps(size, 0.006, 2.2, seed + 1)
        d = 0.7 * clods + 0.7 * _pits(size, 0.004, 1.4, seed + 2) + 0.1 * broad(8, 3)
        sm = 0.4 * broad(6, 4) - 0.3 * clods
    elif kind == "sand":
        d = 0.9 * _bumps(size, 0.07, 1.1, seed + 1) + 0.15 * broad(4, 2)
        sm = 0.4 * broad(8, 4)
    elif kind == "snow":
        d = 0.9 * lib.fbm(size, 4, 2, seed)
        glint = (lib.white_noise(size, seed + 6) > 0.992).astype(np.float32)
        sm = 0.4 * broad(4, 4) + 2.0 * glint
    elif kind == "wood":
        grooves, pores = _wood_grain(size, seed)
        d = 1.0 * grooves + 0.5 * pores
        if direction == "v":
            d, grooves = d.T.copy(), grooves.T.copy()
        sm = 0.7 * grooves + 0.3 * broad(3, 5)
    elif kind == "metal":
        # Brushed plate: fine grain in one direction, a few long scratches
        # across it, and smoothness that follows the brushing.
        brush = _aniso_noise(size, 2, 160, seed) + 0.5 * _aniso_noise(size, 4, 96, seed + 1)
        scr = _scratches(size, 6, 70, seed + 3, angle=0.25)
        d = 0.35 * brush + 0.9 * scr
        sm = 0.6 * brush + 1.0 * scr + 0.2 * broad(3, 4)
    elif kind == "metal_worn":
        # Tools, anvils, iron in use: short scratches in every direction,
        # small dents, and rubbed patches that are smoother than the rest.
        scr = _scratches(size, 26, 22, seed + 3)
        dents = _pits(size, 0.0012, 2.2, seed + 5)
        rubbed = np.clip(lib.fbm(size, 3, 2, seed + 7), 0.0, 1.0)
        d = 1.0 * scr + 0.7 * dents + 0.1 * broad(4, 4)
        sm = 1.2 * scr - 0.5 * dents + 0.9 * rubbed
    elif kind == "leaves":
        # Leaf texels are small leaves already, so no drawn vein pattern
        # (a regular one read as fabric). A soft waxy sheen that varies leaf
        # to leaf, a few fine creases in random directions, and small bites.
        creases = _scratches(size, 30, 10, seed + 3)
        bites = _pits(size, 0.0015, 1.4, seed + 5)
        d = 0.6 * creases + 0.6 * bites + 0.15 * broad(10, 2)
        sm = 1.0 * broad(6, 4) + 0.4 * creases
    elif kind == "bark":
        # Bark: many narrow fissures along the log that wander, merge and
        # break, with ridges between; rough in the fissures.
        yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) * (256.0 / size)
        # The wander changes along the log (y) and hardly across it, or the
        # fissures swirl like contour lines.
        wander = 3.0 * _aniso_noise(size, 2, 8, seed) + 1.5 * _aniso_noise(size, 3, 16, seed + 1)
        u = xx + wander
        # Fixed spacing with a small phase wobble: dividing by a spacing that
        # varies across the tile warps the lines further the further out.
        ph = (u / 9.0 + 0.25 * _aniso_noise(size, 3, 6, seed + 2)) % 1.0
        grooves = -np.clip(1.0 - np.abs(ph - 0.5) / 0.16, 0.0, 1.0) ** 1.3
        breaks = lib.fbm(size, 4, 2, seed + 3) > -0.35
        grooves = grooves * breaks
        d = 1.0 * grooves + 0.3 * _pits(size, 0.002, 1.3, seed + 4) + 0.08 * broad(6, 3)
        sm = 0.3 * broad(4, 4) + 0.6 * grooves
    elif kind == "glass":
        # Faint smudges and the odd hairline scratch on a clean pane.
        d = 0.2 * lib.fbm(size, 3, 2, seed) + 0.6 * _scratches(size, 4, 50, seed + 3)
        sm = 0.8 * lib.fbm(size, 4, 2, seed + 4) - 0.4 * (d < -0.3)
    elif kind == "cloth":
        t = np.arange(size) * (256.0 / size)
        weave = np.sign(np.sin(t[:, None] * np.pi / 2.0) * np.sin(t[None, :] * np.pi / 2.0))
        d = 0.5 * weave.astype(np.float32) + 0.2 * broad(8, 2)
        sm = 0.2 * broad(6, 5)
    elif kind == "ice":
        d = 0.5 * lib.fbm(size, 3, 2, seed) + 0.8 * _cracks(size, 5, 70, seed + 3)
        sm = 0.5 * broad(4, 4) - 0.5 * (d < -0.3)
    else:
        return None, None
    return np.clip(d, -1.5, 1.5).astype(np.float32), np.clip(sm, -1.5, 2.0).astype(np.float32)


def micro_field_px(kind, seed, size=None, direction="h"):
    """micro_field for a map of size pixels at this build's resolution. At
    128 the field is drawn at twice the size, which is the 256 build's own
    field, and averaged down two by two: grain spacing, pores, scratches
    and cracks are written in 256 px map pixels, and at 128 the finest of
    them (a one pixel scratch, wood grain three pixels apart, a weave four)
    would land between pixels and alias into stripes and dots. Averaged,
    a feature finer than a pixel fades instead. The detail is then faded
    by lib.MICRO_FADE, so it stands against the steps as it does at 256.
    At 256 and 512 this is micro_field itself."""
    size = lib.SIZE if size is None else size
    f = lib.SUPERSAMPLE
    d, sm = micro_field(kind, seed, size=size * f, direction=direction)
    if d is None or f == 1:
        return d, sm
    return lib.downsample(d, f) * np.float32(lib.MICRO_FADE), lib.downsample(sm, f)


def _fit(field, shape):
    """Tile or crop a square micro field to a map's shape (a tall animation
    strip, a wide atlas)."""
    h, w = shape
    reps = (-(-h // field.shape[0]), -(-w // field.shape[1]))
    return np.tile(field, reps)[:h, :w]


# --- judging ----------------------------------------------------------------
# lib.check's targets (mean tilt, occlusion minimum, smoothness spread) were
# written for the domed, grained look this replaces: a flat plateau has
# almost no mean tilt by design, so every extruded stem failed them. These
# measure what this look promises instead, from the files as written.

def relief_depth(n):
    """tools/../src/goanna_textures.cpp reliefDepth, ported: the parallax
    depth in nodes the client derives from an authored _n map (median of
    normal slope over height gradient, per map width, capped at 0.10)."""
    h, w = n.shape[:2]
    ys, xs = np.mgrid[0:h:2, 0:w:2]
    nx = n[ys, xs, 0] * 2 - 1
    ny = n[ys, xs, 1] * 2 - 1
    nz = np.sqrt(np.clip(1 - nx * nx - ny * ny, 1e-4, 1))
    a = n[..., 3]
    gx = (a[ys, (xs + 1) % w] - a[ys, (xs - 1) % w]) * 0.5
    gy = (a[(ys + 1) % h, xs] - a[(ys - 1) % h, xs]) * 0.5
    g = np.abs(gx) + np.abs(gy)
    r = ((np.abs(nx) + np.abs(ny)) / nz / np.maximum(g, 1e-6))[g > 0.01]
    if r.size < 100:
        return 0.0, 0.0
    raw = float(np.median(r)) / w
    return min(0.10, raw), raw


def _gate():
    import importlib.util
    path = lib.REPO / "tools" / "check-pbr-quality.py"
    spec = importlib.util.spec_from_file_location("check_pbr_quality", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# The class list the release gate is run with, per game, so check() tests
# a stem against the same class the release will (tools/run-pbr-overnight.sh
# passes these). A spec's class can differ; then only a declared smoothness
# lifts the release's cap.
RELEASE_CLASSES = {
    "mineclonia": ("pbr_packs/manifests/mineclonia-terrain-v1.json",
                   "pbr_packs/classification_reviews/mineclonia-v1.json"),
}
_release_cache = {}


def release_class(stem, game):
    if game not in RELEASE_CLASSES:
        return None
    if game not in _release_cache:
        g = _gate()
        manifest, review = (str(lib.REPO / p) for p in RELEASE_CLASSES[game])
        classes = g.texture_classes(manifest)
        # The release reads the review for every stem with source art, not
        # only the manifest's; the game's stem list stands in for that.
        listed = HERE_STEMS / (game + ".txt")
        stems = set(classes) | (set(listed.read_text().split()) if listed.exists() else set())
        reviews = g.pbr_bake.load_classification_review(review, stems)
        for s, r in reviews.items():
            if r.get("primary_material"):
                classes[s] = g.pbr_bake.physical_class(r["primary_material"])
        _release_cache[game] = (classes, reviews)
    return _release_cache[game][0].get(stem)


def release_review(stem, game):
    """The classification review entry the release gate applies to a stem
    (its smoothness bounds among other things), or None."""
    if release_class(stem, game) is None and game not in _release_cache:
        return None
    return _release_cache.get(game, ({}, {}))[1].get(stem)


def check(stem, out_dir, game=lib.DEFAULT_GAME, spec=None):
    """Pass or fail lines for an extruded stem."""
    from PIL import Image
    spec = load_spec(stem, game) if spec is None else spec
    cls = spec.get("class") or stem_class(stem, game)
    out_dir = Path(out_dir)
    n = np.asarray(Image.open(out_dir / (stem + "_n.png")).convert("RGBA")).astype(np.float32) / 255.0
    s = np.asarray(Image.open(out_dir / (stem + "_s.png")).convert("RGBA")).astype(np.float32) / 255.0
    src = lib.load_source(stem, game)
    rows, art = src.shape[:2]
    cell = lib.SIZE // art
    alpha = src[..., 3] if src.shape[-1] == 4 else np.ones((rows, art), np.float32)
    drawn = alpha >= 0.5
    lines = []

    def line(ok, text):
        lines.append(("ok   " if ok else "FAIL ") + text)

    # On the grid: inside each texel, away from its one pixel chamfer, the
    # height is one value. Grain or noise inside a texel fails this.
    # Leave at least one pixel of each texel to measure: a 64 px model
    # atlas (a bed, the lectern) has texels only four map pixels wide.
    edge = min(chamfer_px(spec, cell) + 1, (cell - 1) // 2)
    hmap = n[..., 3].reshape(rows, cell, art, cell)[:, edge:cell - edge, :, edge:cell - edge]
    spread = hmap.max(axis=(1, 3)) - hmap.min(axis=(1, 3))
    share = float((spread[drawn] <= 2.5 / 255).mean()) if drawn.any() else 1.0
    line(share >= 0.98, "on the texel grid %.0f%% of drawn texels (want >= 98)" % (100 * share))

    # Relief exists: the drawn texels take several heights.
    tex_h = np.round(hmap.mean(axis=(1, 3)) * 255)[drawn]
    levels = len(np.unique(tex_h))
    modes = [m.get("mode", "shade") for m in (spec.get("materials") or {"b": {}}).values()]
    flat_only = all(m == "flat" for m in modes)
    # Only a shaded material promises several heights; a plate of flat
    # frame and solid panels (cut copper) has two on purpose.
    line("shade" not in modes or levels >= 3, "%d distinct texel heights (want >= 3)" % levels)

    # The depth the client will march, and whether its cap cut the map.
    depth, raw = relief_depth(n)
    # A stem that is all flat material (a single colour of concrete) has
    # no relief on purpose, so only the cap applies to it.
    # Cloth is kept shallow so its rim term stays on the silhouette.
    floor = 0.005 if cls == "cloth" else 0.02
    line((flat_only or raw >= floor) and raw <= 0.105,
         "parallax depth %.3f node%s (want %.3f to 0.10%s)"
         % (depth, "" if raw <= 0.105 else ", clipped from %.3f" % raw, floor,
            ", or none when all flat" if flat_only else ""))

    # Tiling at texel joins. The art's own wrap is its design, so a height
    # seam only fails where the albedo has none.
    seam_h = lib.seam_energy(n[..., 3], cell)
    seam_a = lib.seam_energy(np.kron(src[..., :3], np.ones((cell, cell, 1), np.float32)), cell)
    # Height is a function of each texel's colour and material, so any
    # seam it has is the art's (a framed block's frame sits on the tile
    # edge by design). Reported, never failed.
    lines.append("note height seam %.2f at texel joins (albedo %.2f)" % (seam_h, seam_a))

    # Smoothness stays in the byte's usable range on drawn texels, and the
    # client's mean per layer is what the far field will use.
    up = np.kron(drawn, np.ones((cell, cell), bool))
    sm = s[..., 0][up] if up.any() else s[..., 0].ravel()
    line(sm.max() <= 0.951, "smoothness %.2f to %.2f, mean %.2f" % (sm.min(), sm.max(), sm.mean()))

    # Holes carry the neutral fill the shader expects.
    holes = ~up
    if holes.any():
        neutral = np.array(lib.pbr_bake.NEUTRAL_N, np.float32) / 255.0
        line(bool(np.all(np.abs(n[holes] - neutral) < 1.5 / 255)), "cut-out holes neutral")

    # The release gate, run on the same files with the same class.
    g = _gate()
    rep = g.inspect(stem, out_dir / (stem + "_n.png"), out_dir / (stem + "_s.png"),
                    release_class(stem, game) or cls,
                    lib.source_path(stem, game), out_dir / (stem + ".png"),
                    release_review(stem, game))
    for f in rep["failures"]:
        line(False, "gate: " + f)
    for w in rep["warnings"]:
        lines.append("note gate: " + w)
    return lines


def palette_map(stem, game=lib.DEFAULT_GAME):
    """Print the art's palette and a texel map of palette indices, for an
    author writing a spec."""
    src = lib.load_source(stem, game)
    rgb = np.clip(np.round(src[..., :3] * 255.0), 0, 255).astype(int)
    alpha = src[..., 3] if src.shape[-1] == 4 else np.ones(src.shape[:2])
    cols, inv = np.unique(rgb.reshape(-1, 3), axis=0, return_inverse=True)
    inv = inv.reshape(src.shape[:2])
    lum = lib.luminance(cols / 255.0)
    for i, c in enumerate(cols):
        print("%3d #%02x%02x%02x lum %.2f n %d" % (i, *c, lum[i], (inv == i).sum()))
    for y in range(src.shape[0]):
        print(" ".join(" ." if alpha[y, x] < 0.5 else "%2d" % inv[y, x] for x in range(src.shape[1])))


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("out_dir")
    ap.add_argument("stems", nargs="+")
    ap.add_argument("--game", default=lib.DEFAULT_GAME)
    ap.add_argument("--palette", action="store_true", help="print palette maps and stop")
    a = ap.parse_args()
    for s in a.stems:
        if a.palette:
            print("==", s)
            palette_map(s, a.game)
            continue
        build(s, a.out_dir, a.game)
        lines = check(s, a.out_dir, a.game)
        bad = [l for l in lines if l.startswith("FAIL")]
        print("%-44s %s" % (s, "pass" if not bad else "; ".join(l[5:] for l in bad)))
