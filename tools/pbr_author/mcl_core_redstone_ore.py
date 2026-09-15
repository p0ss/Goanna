"""Hand authored LabPBR height and smoothness for mcl_core_redstone_ore.

The 16 px art's grey texels are default_stone's own palette pixel for
pixel, zero distance from one of its six colours. Seventy nine texels sit
0.10 to 0.37 further out, a clean gap above the matrix's zero, with a red
cast (r above g by up to 0.69, against the matrix's own 0.02 to 0.05) that
nothing in the plain rock carries. Redstone is one large clump, not two
like lapis: it forms broad, nearly flat facets rather than a raised
crystal point, with a glitter of bright flecks across the flat faces.
"""
import sys

import numpy as np

import lib

STEM = "mcl_core_redstone_ore"
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

    ore_mask = dist > 0.05
    print(f"ore texels: {int(ore_mask.sum())} of {ore_mask.size}")
    r, g = rgb[..., 0], rgb[..., 1]
    print(f"ore texel r-g range: {(r-g)[ore_mask].min():.3f} to {(r-g)[ore_mask].max():.3f} "
          f"(matrix range {(r-g)[~ore_mask].min():.3f} to {(r-g)[~ore_mask].max():.3f}), a red cast")

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

    ore_labels_hi = lib.warp_labels(ore_labels, amp=8.0, seed=71)
    ore_present_hi = ore_region_is_ore[ore_labels_hi]
    ore_edges = lib.region_edges(ore_labels_hi)
    ore_max_dist = 5
    ore_dist = lib.distance_to_edge(ore_edges, max_dist=ore_max_dist)
    ore_t = np.clip(ore_dist / ore_max_dist, 0.0, 1.0)
    ore_t = ore_t * ore_t * (3 - 2 * ore_t)
    ore_t = np.where(ore_present_hi, ore_t, 0.0)

    # Flat facets: the same posterising trick as the sharp gems, but at a
    # much lower amplitude, so the planes barely step at all and read as
    # flat rather than jagged. The glitter itself is a sparse, very fine
    # bright fleck, not part of the shape, so it stays a small amount.
    raw = lib.fbm(lib.SIZE, base_cells=8, octaves=2, seed=72, gain=0.5)
    levels = 3.0
    facet = np.round(raw * levels) / levels * 0.03
    glitter = lib.white_noise(lib.SIZE, seed=73) * 0.015
    ore_height = 0.86 + facet + glitter

    height = matrix_height * (1 - ore_t) + ore_height * ore_t
    height = lib.normalise01(height, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Glittery: a moderate smooth boost for the flat faces, with a sparkle
    # term riding on top that spikes a few isolated texels bright, the way
    # a crystal glints rather than shines evenly.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=13)
    sparkle = np.clip(lib.white_noise(lib.SIZE, seed=74), 0.55, 1.0) - 0.55
    smooth = 0.5 * height + 0.55 * rough_noise + ore_t * 0.28 + ore_t * sparkle * 0.9
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    # Subtly emissive: the ore texels glow a little, brighter at their
    # reddest, the way an activated redstone vein reads even when nothing
    # else lights it. The matrix stays at zero, which pack() encodes as no
    # emission at all (alpha 255).
    red_cast = albedo[..., 0] - albedo[..., 1]
    ore_red = red_cast[ore_present_hi]
    lo, hi = float(ore_red.min()), float(ore_red.max())
    redness = np.clip((red_cast - lo) / max(hi - lo, 1e-6), 0.0, 1.0)
    emission = np.where(ore_present_hi, 0.25 + 0.15 * redness, 0.0)
    print(f"emission on ore: mean {emission[ore_present_hi].mean():.3f}, "
          f"max {emission[ore_present_hi].max():.3f} (want 0.25 base, 0.4 at the reddest)")

    normal_strength = 36
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, emission=emission)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    for line in lib.check(m, CLS):
        print(line)
    s_back = np.asarray(lib.Image.open(str(out_dir) + "/" + STEM + "_s.png").convert("RGBA")).astype(np.float32) / 255.0
    print(f"ore texel A after packing: mean {s_back[..., 3][ore_present_hi].mean():.3f} "
          f"(want below 1.0), matrix A mean {s_back[..., 3][~ore_present_hi].mean():.3f} (want 1.0)")
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")


if __name__ == "__main__":
    main()
