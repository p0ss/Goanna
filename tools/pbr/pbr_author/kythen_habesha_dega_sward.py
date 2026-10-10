"""Hand authored height and smoothness for kythen_habesha_dega_sward.

The 32 px art is a dithered olive and yellow green mat, four grey shades,
mean saturation 0.224: real colour variation, not a tint a shader multiplies
over a grey source, so it is read here as is rather than as a leaves style
tinted greyscale. lib.segments (tolerance 0.05) finds 126 regions, one of
358 texels and many small ones, the dense overlapping tussocks a highland
sward (dega, the cool upland pasture belt) shows from directly above: no
single blade is drawn, only where the light gets between tussocks and where
it does not. lib.class_of reads "soil": a grazed highland sward is a tight,
low mat rather than the taller upright blades of a lawn top, closer to a
dense ground cover than to leaves.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_dega_sward"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"lib.class_of reads: {CLS}")

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}, sizes top10 {sorted(sizes.tolist(), reverse=True)[:10]}")

    baseline = 0.06
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.58 + 0.37 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=4.5, seed=101)
    edges = lib.region_edges(labels_hi)
    max_dist = 2  # tussocks pack tight, a narrow real gap between them
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # Tussocks clump at a scale above the segmented dither.
    tussocks = lib.fbm(SIZE, base_cells=16, octaves=3, seed=102, gain=0.55) * 0.30

    grit = lib.blur(lib.white_noise(SIZE, seed=103), 1) * 0.06
    pits = lib.blur(lib.white_noise(SIZE, seed=104), 2) * 0.05
    # One real gap down between tussocks where the sward has not closed.
    hole_field = lib.blur(lib.white_noise(SIZE, seed=105), 1)
    hole_cut = float(np.percentile(hole_field, 0.2))
    holes = np.where(hole_field < hole_cut, (hole_field - hole_cut) * 14.0, 0.0)

    height = lib.normalise01(layout + tussocks + grit + pits + holes, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=106, gain=0.55)
    smooth = 0.45 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 10.0
    height = lib.band(height, 0.32)
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
