"""Hand authored height and smoothness for mcl_core_sandstone_top.

The cut face: mean luminance 0.637, standard deviation only 0.027, far
tighter than the side (0.088) or the bottom (0.061). lib.segments at
tolerance 0.02 finds two big regions of 67 and 64 texels, both the same
shade 0.653, which between them cover more than half the art: that is the
flat matrix of the cut, not a bed or a stone. The rest of the 76 regions
are small, one to six texels, sitting a little below the matrix (0.601,
0.621, a handful even lower at 0.565) or a little above it (0.682): subtle
grain in an otherwise flat face, not the pitting default_stone's rougher
mottle shows.

Shares its fine grain and pore noise with mcl_core_sandstone_normal and
_bottom (seeds 61, 62) so the three faces read as one stone; the fleck
layout here is its own, much shallower, because this face is the flattest
of the three.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_sandstone_top"
CLS = "sand"
SIZE = lib.SIZE

GRAIN_SEED = 61
PORES_SEED = 62


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")

    tolerance = 0.02
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:12], "...")
    matrix = region_lum[np.argmax(sizes)]
    print(f"matrix shade {matrix:.3f}, {int((sizes >= 60).sum())} regions that big")

    # Target height per fleck, a shallow nudge either side of the matrix:
    # this is a cut face, not a mottled slab, so the flecks are subtle
    # grain, not real pits or crystal the way default_stone's are.
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.42 + 0.16 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=3.0, seed=74)
    edges = lib.region_edges(labels_hi)
    max_dist = 2  # flecks are one to six texels; a tight taper keeps them as grain, not lumps
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = 0.5 + (target[labels_hi] - 0.5) * t

    # Same fine grain and pores as the other two sandstone faces, but at a
    # third the weight: this face is the flat cut, not the weathered ones.
    grain = lib.fbm(SIZE, base_cells=44, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.018
    pores = lib.blur(lib.white_noise(SIZE, seed=PORES_SEED), 1) * 0.018
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height with the face's own light variation: a
    # cut face wears evenly, so the spread is narrower than the other two
    # faces' own smoothness fields.
    rough_noise = lib.fbm(SIZE, base_cells=26, octaves=3, seed=75, gain=0.55)
    smooth = 0.55 * height + 0.45 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 6.5
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
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
