"""Hand authored height and smoothness for kythen_habesha_grove_litter.

The 32 px art is a dark, mottled green dither, luminance 0.24 to 0.39.
lib.segments (tolerance 0.05) finds 105 regions, one dominant 349 texel
patch and a spread of 40 to 60 texel clusters down to 38 lone texels: fallen
leaves overlapping in a grove floor, not a drawn network of individual
leaf shapes. The lighter clusters are leaves lying flatter and catching
more light, the darker gaps are where the litter is deeper or shadowed
between overlapping leaves. lib.class_of reads "soil": litter builds up
into a compressible mat rather than the springy upright structure leaves
gets.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_grove_litter"
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

    baseline = 0.10
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.50 + 0.40 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=5.5, seed=141)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # Overlapping leaves clump at a scale above the segmented dither, no
    # preferred direction the way a curled leaf can lie any way up.
    clumps = lib.fbm(SIZE, base_cells=14, octaves=3, seed=142, gain=0.55) * 0.28

    grit = lib.blur(lib.white_noise(SIZE, seed=143), 1) * 0.06
    pits = lib.blur(lib.white_noise(SIZE, seed=144), 2) * 0.05
    height = lib.normalise01(layout + clumps + grit + pits, 0.5, 99.5)
    height = lib.band(height, 0.30)

    # One real deep gap down to the ground between leaves, not the litter's
    # ordinary shallow overlap.
    hole_field = lib.blur(lib.white_noise(SIZE, seed=145), 1)
    hole_cut = float(np.percentile(hole_field, 0.3))
    holes = np.where(hole_field < hole_cut, (hole_field - hole_cut) * 3.2, 0.0)
    height = np.clip(height + holes, 0.0, 1.0)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=146, gain=0.55)
    smooth = 0.45 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 8.0
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
