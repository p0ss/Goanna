"""Hand authored height and smoothness for kythen_moana_coral_soil.

The 32 px art has luminance 0.353 to 0.725, sd 0.085, the widest spread of
the moana soils. lib.segments (tolerance 0.03) finds 301 regions with no
single dominant background, the biggest only 138 texels (13 percent), the
next dozen all 20 to 39 texels: a fine, numerous crumb rather than a few
big clods, and paler than kythen_moana_ash_loam's own dark fine soil. This
is the brief's pale soil with coral grit: the clod layout is built the same
way as default_dirt.py's own crumb, and a separate sharper white noise
layer stands in for the ground coral fragments mixed through it, finer and
harder edged than the loam's own soft grit.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_coral_soil"
CLS = "soil"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("class_of reads:", lib.class_of(STEM, GAME))

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])

    lo, hi = region_lum.min(), region_lum.max()
    target = 0.18 + 0.60 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=6.0, seed=851)
    edges = lib.region_edges(labels_hi)
    max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 1.1 * (narrow - wide)

    # Lumpiness above the segmented scale, coral grit below it: a sharper,
    # more sparkling scatter than ash_loam's soft grit, standing in for
    # the ground coral fragments mixed through the soil.
    lumps = lib.fbm(SIZE, base_cells=12, octaves=3, seed=852, gain=0.55) * 0.26
    coral_grit = lib.white_noise(SIZE, seed=853) * 0.05
    # A scatter of small, genuinely deep pits (a low percentile cut, not a
    # broad shallow noise): the horizon based ambient occlusion needs a
    # wall that rises within a texel or two.
    pit_field = lib.blur(lib.white_noise(SIZE, seed=854), 2)
    pit_cut = float(np.percentile(pit_field, 30))
    pits = np.where(pit_field < pit_cut, pit_field - pit_cut, 0.0) * 3.8

    height = lib.normalise01(layout + lumps + coral_grit + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=855, gain=0.55)
    smooth = 0.42 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 10.5
    height = lib.band(height, 0.58)
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
