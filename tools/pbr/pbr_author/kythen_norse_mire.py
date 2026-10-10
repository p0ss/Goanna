"""Hand authored LabPBR height and smoothness for kythen_norse_mire,
standing wet peat, nearly flat and smooth underfoot.

The 32 px art carries almost no signal: two shades, 0.223 and 0.234, one
texel apart, in a fine dither with no regions lib.segments can find (every
tolerance from 0.02 up collapses the whole tile to one region). There is
nothing here to read a layout from, the way kythen_habesha_terrace_face.py
found no layout in its own art: this is a soft, saturated mat, and the
relief below is built the way kythen_firecountry_reed_peat.py builds its
own peat, broad soft hummocks and sparse settled hollows at a scale well
under the art's own texel, kept to a narrow band because standing water on
peat is close to level.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_mire"
CLS = "soil"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    cls_read = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {cls_read}, using {CLS}")
    for tol in (0.02, 0.06, 0.1):
        labels, n = lib.segments(rgb, tolerance=tol)
        print(f"segments at tolerance {tol}: n={n}")

    # No layout to read: broad soft hummocks where the mat has settled
    # unevenly, plus sparse deep hollows for real occlusion. A continuous
    # excess-over-threshold dip (as kythen_firecountry_reed_peat.py uses)
    # plateaus around ao min 0.39 here: too gentle a wall for the ao pass
    # to read as a real recess. A binary hollow mask with a short, steep
    # taper (the same distance_to_edge device the masonry stems use for
    # their joints) gives a genuine flat-floored pit instead.
    hummock = lib.fbm(lib.SIZE, base_cells=8, octaves=3, seed=121, gain=0.55) * 0.06
    hollow_field = lib.blur(lib.white_noise(lib.SIZE, seed=122), 2)
    hollow_cut = float(np.percentile(hollow_field, 28))
    hollow_mask = hollow_field < hollow_cut
    max_dist = 3
    dist = lib.distance_to_edge(hollow_mask.astype(np.float32), max_dist=max_dist)
    tt = np.clip(dist / max_dist, 0.0, 1.0)
    tt = tt * tt * (3 - 2 * tt)  # 0 at the hollow floor, 1 on the level mat
    hollows = (tt - 1.0) * 0.55

    fuzz = lib.blur(lib.white_noise(lib.SIZE, seed=123), 1) * 0.02
    height = lib.normalise01(hummock + hollows + fuzz, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: a wet peat surface, high and fairly even, a shade rougher
    # in the settled hollows where debris collects.
    variation = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=124, gain=0.55)
    smooth = 0.55 + 0.60 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 4
    height = lib.band(height, 0.40)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
