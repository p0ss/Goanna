"""Hand authored height and smoothness for kythen_habesha_highland_subsoil.

The 32 px art has an almost flat luminance, 0.213 to 0.238, standard
deviation only 0.010: reading brightness alone finds nothing. Its colour
does carry real structure though (mean saturation 0.105, up to 0.176), a
grey brown subsoil shade against a redder clay shade, and lib.segments
(tolerance 0.05, RGB distance rather than luminance alone) finds it: ten
regions, two dominant ones of 568 and 345 texels and a handful of small
transitional pieces between them. That is two clod types sitting together,
a neutral subsoil clod and a redder clay clod, each large enough to be a
real clod rather than dirt's fine crumb. lib.class_of reads "soil".
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_highland_subsoil"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    sat = rgb.max(-1) - rgb.min(-1)
    print(f"sat mean {sat.mean():.3f} max {sat.max():.3f}")
    print(f"lib.class_of reads: {CLS}")

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    # Height reads off each region's own hue, not its luminance, since
    # luminance barely varies here: the red channel's excess over green
    # tells the clay shade from the neutral one.
    hue = rgb[..., 0] - rgb[..., 1]
    region_hue = np.array([hue[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}, sizes {sorted(sizes.tolist(), reverse=True)}")

    baseline = 0.12
    lo, hi = region_hue.min(), region_hue.max()
    target = 0.50 + 0.40 * (region_hue - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=6.0, seed=161)
    edges = lib.region_edges(labels_hi)
    max_dist = 5  # these clods are big, a broad rounded taper suits them
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # A clod's own uneven, cracked surface, a scale below the two big clod
    # regions themselves.
    cracks = lib.fbm(SIZE, base_cells=14, octaves=3, seed=162, gain=0.55) * 0.28

    grit = lib.blur(lib.white_noise(SIZE, seed=163), 1) * 0.06
    pits = lib.blur(lib.white_noise(SIZE, seed=164), 2) * 0.05
    height = lib.normalise01(layout + cracks + grit + pits, 0.5, 99.5)
    height = lib.band(height, 0.32)

    # One real deep crack between the clods, not the surface's ordinary
    # shallow cracking.
    hole_field = lib.blur(lib.white_noise(SIZE, seed=165), 1)
    hole_cut = float(np.percentile(hole_field, 0.3))
    holes = np.where(hole_field < hole_cut, (hole_field - hole_cut) * 3.2, 0.0)
    height = np.clip(height + holes, 0.0, 1.0)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=166, gain=0.55)
    smooth = 0.45 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 13.0
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
