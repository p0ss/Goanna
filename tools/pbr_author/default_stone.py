"""Hand authored LabPBR height and smoothness for default_stone.

The 16 px art is a mottled grey with six shades, mean luminance 0.487,
standard deviation only 0.045. There is no cobble style layout of separate
stones; it is one continuous slab, and the flecks are pitting and grain in
that one surface: the two darkest shades (0.389, 0.425) are where the rock
has pitted, the two lightest (0.544, 0.602) are raised crystal grain, and
the middle two (0.462, 0.507) are the untouched matrix in between.
"""
import sys

import numpy as np

import lib

STEM = "default_stone"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    # Connected regions of near identical colour. The six shades sit 0.035
    # to 0.045 apart, comfortably wider than 0.03, so this tolerance groups
    # a fleck's texels without bridging to the next shade: 85 regions, most
    # one to six texels, a few chains of the matrix shade up to 30. That is
    # the true grain of this art: lots of small flecks, not a handful of
    # regions the way cobble's stones are.
    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    # Target height per fleck: a continuous mapping from shade to height
    # spreads the depth thinly across all 85 flecks and every one comes out
    # a shallow nudge, nowhere near deep enough to occlude. Pitting and
    # grain are what they are because they properly break from the matrix,
    # so only the two darkest shades are cut down as real pits, only the two
    # lightest are raised as real grain, and the two middle shades stay the
    # untouched matrix at the neutral level.
    baseline = 0.5
    pit = region_lum < 0.45
    grain_mask = region_lum > 0.53
    print(f"pit flecks: {int(pit.sum())}, grain flecks: {int(grain_mask.sum())}, "
          f"matrix flecks: {int(n - pit.sum() - grain_mask.sum())}")
    target = np.where(pit, 0.34, np.where(grain_mask, 0.64, baseline))

    labels_hi = lib.warp_labels(labels)
    edges = lib.region_edges(labels_hi)
    max_dist = 5  # soft mounds and dishes, not outlined pieces: the tight taper read as a jigsaw under a lamp
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: rounds a square fleck into a rounded pit or dome
    layout = baseline + (target[labels_hi] - baseline) * t

    # Sub texel structure: fine mineral grain a couple of texels across, and
    # sparser pores about a texel across, both far below the layout in
    # scale but not so faint they vanish next to it.
    grain = lib.fbm(lib.SIZE, base_cells=40, octaves=3, seed=11, gain=0.55) * 0.04
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=12), 1) * 0.05
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: pits gather dust and stay rough, raised
    # grain is what wears smooth. The stone's own patchy variation rides on
    # top; pack() moves the mean to the class level, we only owe the spread.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=13)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the fleck edges the height field lines up with.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 40
    # Held in a band scaled to the surface's real depth: full range
    # domes read as rubble under a grazing lamp on the ramp.
    height = lib.band(height, 0.15)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    for line in lib.check(m, CLS):
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")


if __name__ == "__main__":
    main()
