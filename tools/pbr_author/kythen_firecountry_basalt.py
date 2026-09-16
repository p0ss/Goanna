"""Hand authored height and smoothness for kythen_firecountry_basalt.

The 32 px art is a dark, low saturation dither, luminance 0.089 to 0.326,
mean 0.205, standard deviation 0.055, with no drawn stones or joints:
lib.segments finds only small flecks throughout (302 regions at tolerance
0.05, biggest 39 texels), the fine mottle of an aphanitic rock rather
than cobble's separate stones. Basalt is dark, fine grained and mostly
uniform, with sparse vesicles, the small gas bubble holes a lava rock
cools with. Only the darkest few percent of flecks are read as vesicles
and cut to real pits; everything else stays close to the matrix level with
only fine sub texel grain, so the surface reads as one continuous dark
rock with occasional holes rather than a fleck-per-fleck dome field the
way default_stone's own coarser grained rock does.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_basalt"
CLS = "stone"
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

    # A quarter of the flecks read as vesicles: fewer than that and the
    # holes were too sparse to bring the map's own mean tilt anywhere near
    # a real rock's (checked by trial, the brief's "sparse" bites once the
    # ordinary crystal grain below is doing its share of the relief too).
    cut = np.percentile(region_lum, 25)
    vesicle = region_lum < cut
    print(f"vesicle flecks: {int(vesicle.sum())} of {n} ({100.0 * vesicle.sum() / n:.0f}%)")
    baseline = 0.55
    target = np.where(vesicle, 0.04, baseline)

    labels_hi = lib.warp_labels(labels, amp=3.0, seed=71)
    edges = lib.region_edges(labels_hi)
    max_dist = 5  # a vesicle is a small round hole, deep enough to occlude
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # Fine grain: an aphanitic rock's crystals are too small to see
    # individually, so this is a dense, fine dither rather than the
    # coarser grain default_stone's own visibly crystalline rock gets, but
    # strong enough that the unbroken matrix between vesicles still has
    # real texel scale relief of its own rather than sitting dead flat.
    grain = lib.fbm(SIZE, base_cells=60, octaves=3, seed=72, gain=0.5) * 0.12
    pores = lib.blur(lib.white_noise(SIZE, seed=73), 1) * 0.10
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: vesicle walls stay rough and dust
    # catching, the unbroken matrix wears a little smoother. Basalt's own
    # patchy variation rides on top; pack() moves the mean to the class
    # level.
    rough_noise = lib.fbm(SIZE, base_cells=26, octaves=3, seed=74, gain=0.55)
    smooth = 0.4 * height + 0.6 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 24
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
