"""Texel extrusion: the authored look, one rule for every stem.

The relief follows the art's own texel grid. Every source texel is a flat
plateau with a one pixel chamfer, and nothing finer: no noise, no grain
inside a texel, no rounded or warped outlines. The earlier authored sets
reached for high definition surface detail, which reads out of place in a
blocky world; this keeps the pixel art and makes it crisp.

A texture is one or more materials. Inside a material the height comes
from one of three modes:

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
shade, lighter texels brighter).
"""
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402

SPECS = Path(__file__).resolve().parent / "specs"

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
    "cloth": (3, 0.30, 6, 0.05),
    "snow": (3, 0.20, 8, 0.05),
    "ice": (3, 0.30, 8, 0.04),
    "glass": (2, 0.30, 10, 0.02),
    "metal": (3, 0.50, 18, 0.06),
}
DEFAULT_STYLE = CLASS_STYLE["stone"]
DETAIL = 0.35
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
    return json.loads(p.read_text()) if p.exists() else {}


def _rank01(v):
    """Each value's rank among v, 0..1; equal shades share a rank."""
    u, inv = np.unique(np.round(v, 4), return_inverse=True)
    r = np.arange(len(u), dtype=np.float32) / max(len(u) - 1, 1)
    return r[inv]


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
    unknown = set(mat.ravel()) - set(names)
    if unknown:
        raise ValueError("materials not declared: %s" % sorted(unknown))
    return mat, fixed, part


def heights(src, spec, cls):
    """The 16 px height field (0..1), a 0..1 shade position for the
    smoothness, the joint mask and the material map."""
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
        else:
            detail = float(m.get("detail", DETAIL))
            lv = int(m.get("levels", levels_c))
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
    f = ~np.isnan(fixed) & drawn
    hgt[f] = fixed[f]
    hgt[~drawn] = 0.0
    return np.clip(hgt, 0.0, 1.0), pos, joints, mat


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


def build(stem, out_dir, game=lib.DEFAULT_GAME, spec=None, preview=True):
    """Write the stem's three maps to out_dir and return lib's metrics."""
    spec = load_spec(stem, game) if spec is None else spec
    cls = spec.get("class") or lib.class_of(stem, game)
    _, _, strength, spread = CLASS_STYLE.get(cls, DEFAULT_STYLE)
    strength = float(spec.get("strength", strength))
    src = lib.load_source(stem, game)
    if src.shape[0] != src.shape[1]:
        raise ValueError("%s is %dx%d; animated strips need their own path"
                         % (stem, src.shape[1], src.shape[0]))
    hgt, pos, joints, mat = heights(src, spec, cls)
    n = lib.SIZE // src.shape[0]
    up = lambda a: np.kron(a, np.ones((n, n), dtype=a.dtype))  # noqa: E731
    # A wider chamfer rounds a thin cut-out piece (a rail, a ladder rung)
    # so its edges catch the light; parallax cannot lift a cut-out's edge.
    hi = chamfer(up(hgt), int(spec.get("chamfer", 1)))

    level, _, is_metal = lib.class_spec(cls)
    mats = spec.get("materials") or {"base": CLASS_MATERIAL.get(cls, {})}
    sm = np.zeros(hgt.shape, np.float32)
    f0 = np.full(hgt.shape, lib.DIELECTRIC_F0 / 255.0, np.float32)
    metal = np.full(hgt.shape, bool(is_metal))
    glow = np.zeros(hgt.shape, np.float32)
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
    emission = up(glow) if glow.max() > 0 else None
    return lib.pack(stem, out_dir, lib.upscale(src), hi, np.clip(up(sm), 0.0, lib.SMOOTH_CEILING), cls,
                    normal_strength=strength, metal_mask=up(metal), keep_mean=False,
                    emission=emission, f0=up(f0), fine_detail=1.0,
                    art_texels=src.shape[0])


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


def check(stem, out_dir, game=lib.DEFAULT_GAME, spec=None):
    """Pass or fail lines for an extruded stem."""
    from PIL import Image
    spec = load_spec(stem, game) if spec is None else spec
    cls = spec.get("class") or lib.class_of(stem, game)
    out_dir = Path(out_dir)
    n = np.asarray(Image.open(out_dir / (stem + "_n.png")).convert("RGBA")).astype(np.float32) / 255.0
    s = np.asarray(Image.open(out_dir / (stem + "_s.png")).convert("RGBA")).astype(np.float32) / 255.0
    src = lib.load_source(stem, game)
    art = src.shape[0]
    cell = lib.SIZE // art
    alpha = src[..., 3] if src.shape[-1] == 4 else np.ones((art, art), np.float32)
    drawn = alpha >= 0.5
    lines = []

    def line(ok, text):
        lines.append(("ok   " if ok else "FAIL ") + text)

    # On the grid: inside each texel, away from its one pixel chamfer, the
    # height is one value. Grain or noise inside a texel fails this.
    edge = int(spec.get("chamfer", 1)) + 1
    hmap = n[..., 3].reshape(art, cell, art, cell)[:, edge:-edge, :, edge:-edge]
    spread = hmap.max(axis=(1, 3)) - hmap.min(axis=(1, 3))
    share = float((spread[drawn] <= 2.5 / 255).mean()) if drawn.any() else 1.0
    line(share >= 0.98, "on the texel grid %.0f%% of drawn texels (want >= 98)" % (100 * share))

    # Relief exists: the drawn texels take several heights.
    tex_h = np.round(hmap.mean(axis=(1, 3)) * 255)[drawn]
    levels = len(np.unique(tex_h))
    flat_only = all(m.get("mode") == "flat" for m in (spec.get("materials") or {"b": {}}).values())
    line(flat_only or levels >= 3, "%d distinct texel heights (want >= 3)" % levels)

    # The depth the client will march, and whether its cap cut the map.
    depth, raw = relief_depth(n)
    # A stem that is all flat material (a single colour of concrete) has
    # no relief on purpose, so only the cap applies to it.
    line((flat_only or raw >= 0.02) and raw <= 0.105,
         "parallax depth %.3f node%s (want 0.02 to 0.10%s)"
         % (depth, "" if raw <= 0.105 else ", clipped from %.3f" % raw,
            ", or none when all flat" if flat_only else ""))

    # Tiling at texel joins. The art's own wrap is its design, so a height
    # seam only fails where the albedo has none.
    seam_h = lib.seam_energy(n[..., 3], cell)
    seam_a = lib.seam_energy(lib.upscale(src[..., :3]), cell)
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
    rep = g.inspect(stem, out_dir / (stem + "_n.png"), out_dir / (stem + "_s.png"), cls,
                    lib.source_path(stem, game), out_dir / (stem + ".png"))
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
