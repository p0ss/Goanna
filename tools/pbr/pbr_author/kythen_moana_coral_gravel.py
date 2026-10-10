"""Hand authored height and smoothness for kythen_moana_coral_gravel.

The 32 px art has luminance 0.622 to 0.818, sd 0.052, class_of reading
gravel back from the bake. lib.segments (tolerance 0.05) finds 203 regions,
the biggest only 108 texels (11 percent), then 85, 70, 48 and a long tail:
many small angular fragments packed edge to edge, not one background slab,
the same shape of result kythen_habesha_river_gravel.py finds in its own
river pebbles. Built the same way, a gap group (the shadowed cracks between
fragments) and a dome group (the fragments themselves, brightness setting
each one's own height) from a shade split, domed per region with a tight
taper so each small fragment stays a distinct small chip rather than one
smoothed ridge, the full normalise01 range kept since gravel is not a
nearly flat material.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_coral_gravel"
CLS = lib.class_of(STEM, GAME)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}, class_of reads {CLS}")

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes (top 15):", sorted(sizes.tolist(), reverse=True)[:15])

    # A gap group (shadowed cracks between fragments) and a dome group (the
    # fragments), split at the median: the art carries no clean gap in its
    # shade histogram the way river_gravel's does, so the split follows the
    # region count instead, keeping roughly the darker half as gap.
    baseline = 0.08
    cut = float(np.median(region_lum))
    gap = region_lum <= cut
    dome = ~gap
    print(f"gap regions: {int(gap.sum())} of {n}, {int(sizes[gap].sum())} texels; "
          f"dome regions: {int(dome.sum())}, {int(sizes[dome].sum())} texels")
    dlo, dhi = region_lum[dome].min(), region_lum[dome].max()
    target = np.where(gap, baseline,
            0.55 + 0.40 * (region_lum - dlo) / max(dhi - dlo, 1e-6))

    labels_hi = lib.warp_labels(labels, amp=6.0, seed=831)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # fragments are a handful of source texels across
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    grit = lib.fbm(lib.SIZE, base_cells=42, octaves=3, seed=832, gain=0.55) * 0.08
    dirt = lib.blur(lib.white_noise(lib.SIZE, seed=833), 1) * 0.08
    height = lib.normalise01(layout + grit + dirt, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=834)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 18
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
