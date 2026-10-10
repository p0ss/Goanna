"""Hand authored height and smoothness for kythen_firecountry_made_earth.

The 32 px art has real drawn structure: lib.segments (tolerance 0.05) finds
43 regions, from a 239 texel patch of the commonest mid shade down to
lone texels, the same kind of small clod and stone dither default_dirt.py
reads in Mineclonia's own dirt. This is compacted fill, not loose garden
dirt, so the clods are built shallower and packed closer together than
default_dirt's own (a smaller crown fade, a gentler lump field): rammed
earth is a worked material, pressed together course by course, and its
own small stones sit nearly flush rather than standing proud the way a
freshly turned bed's do.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_made_earth"
CLS = "soil"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])

    lo, hi = region_lum.min(), region_lum.max()
    target = 0.20 + 0.55 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=5.0, seed=221)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # compacted fill: a tighter crown fade than default_dirt's own loose crumb
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 0.9 * (narrow - wide)

    # Lumpiness above the segmented regions, shallower than default_dirt's
    # own: this earth was rammed course by course, not left as a loose
    # crumb.
    lumps = lib.fbm(SIZE, base_cells=11, octaves=3, seed=222, gain=0.55) * 0.26

    # Structure below the texel: fine grit and a scatter of small pits,
    # both a shade lighter than default_dirt's own since compaction has
    # pressed most of the air out of it.
    grit = lib.blur(lib.white_noise(SIZE, seed=223), 1) * 0.06
    pit_field = lib.blur(lib.white_noise(SIZE, seed=224), 2)
    pit_cut = float(np.percentile(pit_field, 34))
    pits = np.where(pit_field < pit_cut, pit_field - pit_cut, 0.0) * 4.2

    height = lib.normalise01(layout + lumps + grit + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=225, gain=0.55)
    smooth = 0.40 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 13.0
    height = lib.band(height, 0.45)
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
