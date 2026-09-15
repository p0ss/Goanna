"""Hand authored LabPBR height and smoothness for mcl_core_diamond_ore.

The 16 px art's grey texels are default_stone's own palette pixel for
pixel, zero distance from one of its six colours. Sixty three texels sit
0.07 to 0.42 further out, a clean gap above the matrix's zero, with a cyan
cast (b above r by up to 0.52, against the matrix's own -0.08 to -0.04)
that nothing in the plain rock carries. Those are the diamond, the
sharpest facets in the fleet: a cut gem, not a rounded nugget.
"""
import sys

import numpy as np

import lib

STEM = "mcl_core_diamond_ore"
CLS = "stone"  # lib.class_of(STEM) reads "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lib.class_of reads: {lib.class_of(STEM)}")
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    stone_pal = np.array(sorted(set(map(tuple,
            np.round(lib.load_source("default_stone")[..., :3].reshape(-1, 3), 3).tolist()))))
    dist = np.abs(rgb[:, :, None, :] - stone_pal[None, None, :, :]).max(axis=-1).min(axis=-1)
    print("distance to default_stone's palette:", sorted(set(np.round(dist.ravel(), 3).tolist())))

    ore_mask = dist > 0.04
    print(f"ore texels: {int(ore_mask.sum())} of {ore_mask.size}")
    r, b = rgb[..., 0], rgb[..., 2]
    print(f"ore texel b-r range: {(b-r)[ore_mask].min():.3f} to {(b-r)[ore_mask].max():.3f} "
          f"(matrix range {(b-r)[~ore_mask].min():.3f} to {(b-r)[~ore_mask].max():.3f}), a cyan cast")

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")

    baseline = 0.5
    pit = region_lum < 0.45
    grain_mask = region_lum > 0.53
    target = np.where(pit, 0.15, np.where(grain_mask, 0.85, baseline))

    labels_hi = lib.warp_labels(labels, seed=7)
    edges = lib.region_edges(labels_hi)
    max_dist = 2
    dist_hi = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist_hi / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    matrix_layout = baseline + (target[labels_hi] - baseline) * t

    grain = lib.fbm(lib.SIZE, base_cells=40, octaves=3, seed=11, gain=0.55) * 0.04
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=12), 1) * 0.05
    matrix_height = matrix_layout + grain + pores

    ore_rgb = np.repeat(ore_mask[..., None].astype(np.float32), 3, axis=-1)
    ore_labels, ore_n = lib.segments(ore_rgb, tolerance=0.5)
    ore_region_is_ore = np.array([bool(ore_mask[ore_labels == i].any()) for i in range(ore_n)])
    ore_sizes = np.bincount(ore_labels.ravel())
    print(f"ore clusters: {int(ore_region_is_ore.sum())} regions, sizes "
          f"{sorted(ore_sizes[ore_region_is_ore].tolist(), reverse=True)}")

    ore_labels_hi = lib.warp_labels(ore_labels, amp=8.0, seed=61)
    ore_present_hi = ore_region_is_ore[ore_labels_hi]
    ore_edges = lib.region_edges(ore_labels_hi)
    ore_max_dist = 6
    ore_dist = lib.distance_to_edge(ore_edges, max_dist=ore_max_dist)
    ore_t = np.clip(ore_dist / ore_max_dist, 0.0, 1.0)
    ore_t = ore_t * ore_t * (3 - 2 * ore_t)
    ore_t = np.where(ore_present_hi, ore_t, 0.0)

    # Sharp facets: a low frequency field, posterised into four flat bands
    # so it steps between planes instead of rolling smoothly, the way a cut
    # gem's faces meet at a hard edge rather than a curve. Not Voronoi: the
    # bands come from rounding a continuous noise field, not from a
    # partition invented for the purpose.
    raw = lib.fbm(lib.SIZE, base_cells=10, octaves=2, seed=62, gain=0.5)
    levels = 4.0
    facet = np.round(raw * levels) / levels * 0.09
    sparkle = lib.blur(lib.white_noise(lib.SIZE, seed=63), 1) * 0.02
    ore_height = 0.93 + facet + sparkle

    height = matrix_height * (1 - ore_t) + ore_height * ore_t
    height = lib.normalise01(height, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Diamond is the smoothest thing in the fleet: a cut gem face, much
    # smoother than the matrix around it, with the facet edges themselves
    # carried into the spread through the height term.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=13)
    smooth = 0.5 * height + 0.55 * rough_noise + ore_t * 0.50
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 38
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
