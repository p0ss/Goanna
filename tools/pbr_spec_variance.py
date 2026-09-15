#!/usr/bin/env python3
"""Give a baked LabPBR specular map the roughness variation the bake left out.

tools/pbr_bake.py writes the smoothness channel of every _s.png as one class
value with, at most, a whisper of Chord's deviation around it: measured on
the Mineclonia pack on 2026-09-15, 44 percent of textures had a smoothness
standard deviation under 0.03 and the grass top ran 0.29 to 0.31 across the
whole tile. One roughness for a whole surface is the defining property of
moulded plastic, and it is what a viewer means by "plastic" whether or not
they can name it. Real stone is polished on the grain tops and dusty in the
cracks; bark is rough everywhere but rougher in its furrows.

This pass derives that variation from the maps the bake already has, so it
needs no ComfyUI and runs on a pack in place or into a copy:

  height  the _n alpha channel. Recesses collect dust and stay matte,
          raised grain is what wears smooth, so smoothness follows height.
  ao      the _n blue channel, the same story from the other side: what is
          occluded is not what is polished.
  albedo  luminance, a weak term with the sign the class chooses: on a
          stone a dark texel is a crack (rougher), on wood a dark texel
          is the figure in the grain and wears the same as the rest.
  grain   a little tile-periodic noise so a perfectly flat map still
          varies texel to texel, and a mirror never forms on one texel.

The mean is kept exactly where the bake put it, because the class levels
were chosen on purpose (see CLASS_SPEC in tools/pbr_bake.py) and the
"everything is shiny" failure is the level, not the spread. Only the spread
changes. Metals are left alone entirely: their G channel is the material
and their smoothness is already deliberately mid-range. Glass and ice are
left alone too: a mirror with dust on it is the one case where a flat map
is right. Everything else gets a spread whose size is set per class, in
smoothness units, by SPREAD below.

Usage:
  tools/pbr_spec_variance.py <pack textures dir> [--out <dir>] [--stems a,b]
      [--classes <classes.json>] [--spread 1.0] [--dry-run]

Without --out the _s.png files are rewritten in place. --stems limits the
pass to a comma separated list of texture stems, which is how the twelve
core surfaces were judged on the ramp (project/material_ramp.tscn) before
the whole pack was touched. --classes is the same JSON tools/pbr_bake.py
takes; without it the class is read back out of the baked bytes, which
carry it: G says metal, B says which translucent class, and the smoothness
mean is the class level tools/pbr_bake.py wrote. The output says when it
was inferred that way.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import pbr_bake  # noqa: E402  (load_classes, for a nodedef dump)

# Standard deviation of smoothness to aim for, per class, in 0..1 units, and
# the sign of the albedo term (dark texels rougher when positive). Natural
# surfaces get the widest spread; cloth and snow are matte everywhere and
# vary little; glass, ice and metal are skipped (None).
SPREAD = {
    "stone": (0.10, 1.0),
    "wood": (0.09, 0.0),
    "leaves": (0.10, 0.5),
    "sand": (0.05, 0.5),
    "gravel": (0.10, 1.0),
    "snow": (0.05, 0.0),
    "soil": (0.06, 1.0),
    "cloth": (0.03, 0.0),
    "glass": None,
    "ice": None,
    "metal": None,
}
DEFAULT_SPREAD = (0.08, 0.5)
# The smoothness channel's own convention, from tools/pbr_bake.py: G at or
# above this is a metal texel, and a metal texel's smoothness is left as is.
METAL_G = 230


def tile_noise(h, w, seed, cells=8):
    """Smooth, tile-periodic noise in -1..1: bilinear value noise on a
    cells x cells lattice that wraps, so the tile still repeats seamlessly."""
    rng = np.random.default_rng(seed)
    lattice = rng.uniform(-1.0, 1.0, (cells, cells))
    ys = (np.arange(h) / h) * cells
    xs = (np.arange(w) / w) * cells
    y0 = np.floor(ys).astype(int) % cells
    x0 = np.floor(xs).astype(int) % cells
    fy = (ys - np.floor(ys))[:, None]
    fx = (xs - np.floor(xs))[None, :]
    fy = fy * fy * (3 - 2 * fy)
    fx = fx * fx * (3 - 2 * fx)
    y1 = (y0 + 1) % cells
    x1 = (x0 + 1) % cells
    a = lattice[y0][:, x0]
    b = lattice[y0][:, x1]
    c = lattice[y1][:, x0]
    d = lattice[y1][:, x1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def standardise(x):
    sd = float(x.std())
    if sd < 1e-6:
        return np.zeros_like(x)
    return (x - x.mean()) / sd


def vary(stem, textures, cls, spread_scale, seed):
    """Return the new _s array, or None when the texture is left alone."""
    spread = SPREAD.get(cls, DEFAULT_SPREAD)
    if spread is None:
        return None, "class %s is left flat on purpose" % cls
    target_sd, albedo_sign = spread
    target_sd *= spread_scale

    s_path = textures / (stem + "_s.png")
    n_path = textures / (stem + "_n.png")
    a_path = textures / (stem + ".png")
    if not s_path.exists():
        return None, "no _s.png"
    s = np.asarray(Image.open(s_path).convert("RGBA")).astype(np.float32)
    h, w = s.shape[:2]
    smooth = s[..., 0] / 255.0
    metal = s[..., 1] >= METAL_G
    if metal.all():
        return None, "every texel is metal"

    # The three sources, each standardised so the weights below mean what
    # they say whatever the bake's own amplitude was.
    terms = []
    if n_path.exists():
        n = np.asarray(Image.open(n_path).convert("RGBA").resize((w, h), Image.BILINEAR)).astype(np.float32) / 255.0
        terms.append((1.0, standardise(n[..., 3])))   # height: high is smooth
        terms.append((0.5, standardise(n[..., 2])))   # ao: open is smooth
    if a_path.exists() and albedo_sign != 0.0:
        a = np.asarray(Image.open(a_path).convert("RGB").resize((w, h), Image.BILINEAR)).astype(np.float32) / 255.0
        lum = a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722
        terms.append((0.35 * albedo_sign, standardise(lum)))
    terms.append((0.35, standardise(tile_noise(h, w, seed))))
    field = sum(wt * t for wt, t in terms)
    field = standardise(field)

    # Whatever spread the bake left is kept and the derived field is added
    # on top, sized so the result lands on the class target, then the mean
    # is put back exactly where it was. The clamp keeps a dielectric off the
    # mirror end and off the fully matte floor, both of which read as errors
    # on a natural surface.
    have = float(smooth[~metal].std())
    add = np.sqrt(max(target_sd ** 2 - have ** 2, 0.0))
    mean = float(smooth[~metal].mean())
    new = smooth + field * add
    new = np.clip(new, 0.0, 0.9)
    new[~metal] += mean - float(new[~metal].mean())
    new = np.clip(new, 0.0, 0.9)
    out = s.copy()
    out[..., 0] = np.where(metal, s[..., 0], np.clip(new * 255.0, 0, 255))
    return out.astype(np.uint8), "sd %.3f -> %.3f (mean %.3f)" % (have, float(new[~metal].std()), mean)


# CLASS_SPEC's smoothness levels, nearest wins. Sand, cloth, gravel and
# stone sit within a few counts of each other, and get near enough the same
# spread, so a wrong pick among them costs nothing that shows.
LEVELS = sorted((v[0], k) for k, v in pbr_bake.CLASS_SPEC.items() if not v[2])
NAME_HINTS = (("wool", "cloth"), ("plank", "wood"), ("log", "wood"), ("wood", "wood"),
        ("sand", "sand"), ("gravel", "gravel"), ("dirt", "soil"), ("soil", "soil"),
        ("leaves", "leaves"), ("snow", "snow"), ("ice", "ice"), ("glass", "glass"))


def infer_class(stem, textures):
    s_path = textures / (stem + "_s.png")
    if not s_path.exists():
        return None
    s = np.asarray(Image.open(s_path).convert("RGBA"))
    if (s[..., 1] >= METAL_G).mean() > 0.5:
        return "metal"
    sss = int(np.median(s[..., 2]))
    if sss > 65:
        # 65 + sss * 190, from CLASS_SSS in tools/pbr_bake.py
        by_sss = sorted((abs(sss - (65 + v * 190)), k) for k, v in pbr_bake.CLASS_SSS.items())
        return by_sss[0][1]
    for needle, cls in NAME_HINTS:
        if needle in stem:
            return cls
    level = float(s[..., 0].mean()) / 255.0
    return sorted((abs(level - lv), k) for lv, k in LEVELS)[0][1]


def guess_class(stem, classes, textures):
    if stem in classes:
        return classes[stem], True
    return infer_class(stem, textures), False


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("textures", type=Path)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--stems", default="")
    ap.add_argument("--classes", type=Path, default=None)
    ap.add_argument("--spread", type=float, default=1.0)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    classes = pbr_bake.load_classes(str(args.classes)) if args.classes else {}
    stems = [s for s in args.stems.split(",") if s]
    if not stems:
        stems = sorted(p.name[:-6] for p in args.textures.glob("*_s.png"))
    out_dir = args.out or args.textures
    if args.out and not args.dry_run:
        out_dir.mkdir(parents=True, exist_ok=True)

    changed = 0
    for i, stem in enumerate(stems):
        cls, known = guess_class(stem, classes, args.textures)
        arr, note = vary(stem, args.textures, cls, args.spread, args.seed + i)
        tag = "" if known else " (class inferred)"
        if arr is None:
            print("%-40s skip  %s%s" % (stem, note, tag))
            continue
        print("%-40s %-8s %s%s" % (stem, cls or "default", note, tag))
        changed += 1
        if args.dry_run:
            continue
        Image.fromarray(arr, "RGBA").save(out_dir / (stem + "_s.png"))
        if args.out and args.out != args.textures:
            # The ramp and the game read the trio together, so a copy that
            # holds only _s would be read as a texture with no albedo.
            for suffix in (".png", "_n.png"):
                src = args.textures / (stem + suffix)
                if src.exists() and not (out_dir / (stem + suffix)).exists():
                    (out_dir / (stem + suffix)).write_bytes(src.read_bytes())
    print("%d of %d textures given a spread" % (changed, len(stems)))


if __name__ == "__main__":
    main()
