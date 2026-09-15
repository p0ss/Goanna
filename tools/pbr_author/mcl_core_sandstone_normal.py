"""Hand authored height and smoothness for mcl_core_sandstone_normal.

This is the side face: the 16 px art draws horizontal strata, not a mottled
slab or a set of separate stones. Row means make the bedding obvious (row 4
dips to 0.518, rows 5 to 6 rise to 0.70, row 7 dips to 0.487, row 8 rises to
0.696, row 10 dips to 0.502, row 11 rises to 0.680, row 15 dips to 0.502,
everything else sits 0.61 to 0.64) and lib.segments at tolerance 0.08 turns
that into seven real regions, most of them full width bands rather than the
flecks default_stone found: sizes 92, 56, 33, 32, 26 and 16 texels plus one
stray texel, luminance from 0.487 (the darkest bed line, a joint) to 0.701
(the brightest bed, a harder, less weathered layer). That is bedded rock:
each band is one deposit, the dark bands are the joints between them.

The three sandstone faces (this one, _top, _bottom) share their fine grain
and pore noise, same base_cells and same seeds (61 and 62), so the block
reads as one stone rather than three unrelated surfaces.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_sandstone_normal"
CLS = "sand"
SIZE = lib.SIZE

# Shared across the three sandstone faces, so the grain reads as one stone.
GRAIN_SEED = 61
PORES_SEED = 62


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("row means:", np.round(lum.mean(axis=1), 3).tolist())

    tolerance = 0.08
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))
    print("region lum:", np.round(region_lum, 3).tolist())

    # Target height per bed, straight off its own brightness: the darkest
    # band is a joint between beds and sits low, the brightest band is a
    # harder, less weathered layer and sits high.
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.15 + 0.70 * (region_lum - lo) / max(hi - lo, 1e-6)

    # A small warp so the bed boundaries are not perfectly straight (real
    # strata waver a little) without losing the horizontal read, then a
    # tight taper for the slight step the brief asks for at each bed line.
    labels_hi = lib.warp_labels(labels, amp=4.0, seed=71)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = 0.5 + (target[labels_hi] - 0.5) * t

    # Fine grain inside each bed: mineral grain a couple of texels across,
    # and sparser pores about a texel across, shared with the other two
    # sandstone faces.
    grain = lib.fbm(SIZE, base_cells=44, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=PORES_SEED), 1) * 0.05
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the bed lines gather dust and stay rough,
    # the harder bright beds are what wears smooth. The face's own patchy
    # variation rides on top; pack() moves the mean to the class level.
    rough_noise = lib.fbm(SIZE, base_cells=24, octaves=3, seed=73, gain=0.55)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the bed edges the height field lines up with.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 9.0
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
