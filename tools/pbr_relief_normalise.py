#!/usr/bin/env python3
"""Lift a flat baked relief to a target tilt, offline, the way the client does.

GoannaTextureArray (src/goanna_textures.cpp) measures the tilt of every
authored normal map when it builds the array and, when the ninth decile is
under 55 degrees, multiplies the whole pack's normals by up to 4x in the
shader (pack_normal_gain). The Mineclonia bake reaches 20.6 degrees at its
roughest, so in play it is already scaled about 3x, and that is where its
imperfections start to show. This tool does the same lift on disk, so a
lifted map can be put on the ramp beside the bake it came from and beside a
hand authored one, all at the same gain, and judged for what it is.

Two things are done per texture, both mean preserving:

  normal  the tangent xy is scaled so the texture's own mean tilt reaches
          its class target (TARGET_TILT below), z is rebuilt, and the
          result is clamped to 80 degrees so no texel folds over.
  ao      recomputed from the height channel, stretched to the full byte
          range first, with tools/pbr_bake.py's own ao_from_height. The
          bake's occlusion never fell below 0.81 anywhere on the Mineclonia
          pack; a crack that is not dark is not a crack.

Usage:
  tools/pbr_relief_normalise.py <pack textures dir> --out <dir> [--stems a,b]
      [--gain-cap 4.0] [--dry-run]

The class is inferred from the _s bytes and the stem the same way
tools/pbr_spec_variance.py does it. Albedo and _s are copied alongside so
the output directory is a whole pack for the ramp.
"""

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import pbr_bake  # noqa: E402
import pbr_spec_variance  # noqa: E402

# Mean texel tilt in degrees to aim for, per class. Natural broken surfaces
# high, fine grained ones low, smooth ones untouched (None).
TARGET_TILT = {
    "stone": 30.0, "gravel": 32.0, "wood": 22.0, "soil": 20.0,
    "sand": 12.0, "leaves": 24.0, "snow": 10.0, "cloth": 10.0,
    "glass": None, "ice": None, "metal": 15.0,
}
DEFAULT_TILT = 22.0
MAX_TILT_DEG = 80.0


def mean_tilt_deg(xy):
    slope = np.sqrt((xy ** 2).sum(-1)).clip(0.0, 0.999)
    return float(np.degrees(np.arcsin(slope)).mean())


def normalise(stem, textures, cls, gain_cap):
    target = TARGET_TILT.get(cls, DEFAULT_TILT)
    if target is None:
        return None, "class %s left as baked" % cls
    n_path = textures / (stem + "_n.png")
    if not n_path.exists():
        return None, "no _n.png"
    n = np.asarray(Image.open(n_path).convert("RGBA")).astype(np.float32) / 255.0
    xy = n[..., :2] * 2.0 - 1.0
    have = mean_tilt_deg(xy)
    if have < 0.05:
        return None, "normal is flat, nothing to scale"
    gain = min(gain_cap, max(1.0, target / have))
    # Scale the tangent slope, not the angle: what the shader does with
    # pack_normal_gain, so the two agree.
    xy = xy * gain
    slope = np.sqrt((xy ** 2).sum(-1))
    cap = np.sin(np.radians(MAX_TILT_DEG))
    over = slope > cap
    xy[over] *= (cap / slope[over])[..., None]
    z = np.sqrt(np.clip(1.0 - (xy ** 2).sum(-1), 0.0, 1.0))

    height = n[..., 3]
    lo, hi = np.percentile(height, (1.0, 99.0))
    if hi - lo > 1e-3:
        height = np.clip((height - lo) / (hi - lo), 0.0, 1.0)
    ao = pbr_bake.ao_from_height(Image.fromarray((height * 255.0).astype(np.uint8), "L"), wrap=True)

    out = np.zeros_like(n)
    out[..., :2] = xy * 0.5 + 0.5
    out[..., 2] = np.clip(ao, 0.0, 1.0)
    out[..., 3] = height
    got = mean_tilt_deg(xy)
    note = "tilt %.1f -> %.1f deg (gain %.2f), ao min %.2f -> %.2f" % (
            have, got, gain, float(n[..., 2].min()), float(out[..., 2].min()))
    return (np.clip(out * 255.0, 0, 255) + 0.5).astype(np.uint8), note


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("textures", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--stems", default="")
    ap.add_argument("--gain-cap", type=float, default=4.0)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    stems = [s for s in args.stems.split(",") if s]
    if not stems:
        stems = sorted(p.name[:-6] for p in args.textures.glob("*_n.png"))
    if not args.dry_run:
        args.out.mkdir(parents=True, exist_ok=True)
    changed = 0
    for stem in stems:
        cls = pbr_spec_variance.infer_class(stem, args.textures)
        arr, note = normalise(stem, args.textures, cls, args.gain_cap)
        print("%-40s %-8s %s" % (stem, cls or "default", note))
        if args.dry_run:
            continue
        for suffix in (".png", "_s.png") + (() if arr is not None else ("_n.png",)):
            src = args.textures / (stem + suffix)
            if src.exists():
                (args.out / (stem + suffix)).write_bytes(src.read_bytes())
        if arr is not None:
            Image.fromarray(arr, "RGBA").save(args.out / (stem + "_n.png"))
            changed += 1
    print("%d of %d relief maps lifted" % (changed, len(stems)))


if __name__ == "__main__":
    main()
