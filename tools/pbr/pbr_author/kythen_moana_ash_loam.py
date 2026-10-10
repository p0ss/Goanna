"""Hand authored height and smoothness for kythen_moana_ash_loam.

The 32 px art has luminance 0.194 to 0.353, sd 0.036, dark fine soil with
no bright colour signal (mean saturation 0.152, hue r-g steady around
0.076, no separate tint to split on). lib.segments (tolerance 0.03) finds
one dominant background of 577 texels (56 percent) and a long tail of
small clod fragments from 38 texels down to single texels, the same shape
of result default_dirt.py and kythen_dirt.py both find in their own dirt
art: a loose crumb of fine soil, darkest texels the recesses between the
small clods, lightest the clods' own sunlit tops. Built the same way, with
a narrower target range than default_dirt's own since this loam is finer
and less lumpy than Mineclonia's dirt.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_ash_loam"
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
    target = 0.20 + 0.55 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=6.0, seed=811)
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # crown fade half width, regions run a few hires texels wide
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    # A blur of the step, not a taper from each region's own edge, so every
    # crossing shares one ramp with a matched slope on both sides (the same
    # reasoning default_dirt.py gives, since one of the many boundaries
    # always lands on the wrap).
    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 1.1 * (narrow - wide)

    # Lumpiness above the segmented scale, and fine ash grain below the
    # texel plus a scatter of small pits where ash has settled.
    lumps = lib.fbm(SIZE, base_cells=12, octaves=3, seed=812, gain=0.55) * 0.22
    grit = lib.blur(lib.white_noise(SIZE, seed=813), 1) * 0.05
    # A scatter of small, genuinely deep pits, the same percentile cut
    # kythen_firecountry_made_earth.py uses, rather than a broad shallow
    # noise: the horizon based ambient occlusion needs a wall that rises
    # within a texel or two, not a gradual slope.
    pit_field = lib.blur(lib.white_noise(SIZE, seed=814), 2)
    pit_cut = float(np.percentile(pit_field, 30))
    pits = np.where(pit_field < pit_cut, pit_field - pit_cut, 0.0) * 3.8

    height = lib.normalise01(layout + lumps + grit + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=815, gain=0.55)
    smooth = 0.42 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 12.0
    # Held in a band scaled to a fine loam's real depth: full range domes
    # read as rubble under a grazing lamp on the ramp.
    height = lib.band(height, 0.55)
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
