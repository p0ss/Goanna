"""Hand authored LabPBR height and smoothness for mcl_deepslate_copper_ore.

The 16 px art's grey texels are mcl_deepslate's own palette pixel for
pixel, zero distance from one of its nine colours. Thirty seven texels sit
0.16 to 0.35 further out, a clean gap above the matrix's zero, with an
orange cast (r above g by 0.22 to 0.36, against the matrix's own 0.00 to
0.01) that no crack or bedding face carries. Copper, like gold, sits in the
rock as rounded native nuggets, not a cut gem.

lib.class_of(STEM) reads "metal" here (the old bake's own _s crosses 50
percent metal G over the whole tile), the same stray reading
mcl_deepslate_gold_ore gets and for the same reason. Kept as stone, the
same call made there: the block is deepslate with a copper vein in it, and
the metal sheen belongs to the nugget's own smoothness, not a whole tile
F0 flip.
"""
import sys

import numpy as np

import lib

STEM = "mcl_deepslate_copper_ore"
CLS = "stone"


def blur_x(field, radius):
    if radius <= 0:
        return field
    out = field.astype(np.float32)
    k = 2 * radius + 1
    acc = np.zeros_like(out)
    for d in range(-radius, radius + 1):
        acc += np.roll(out, d, axis=1)
    return acc / k


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lib.class_of reads: {lib.class_of(STEM)} (overridden to stone, see docstring)")
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    ds_pal = np.array(sorted(set(map(tuple,
            np.round(lib.load_source("mcl_deepslate")[..., :3].reshape(-1, 3), 3).tolist()))))
    dist = np.abs(rgb[:, :, None, :] - ds_pal[None, None, :, :]).max(axis=-1).min(axis=-1)
    print("distance to mcl_deepslate's palette:", sorted(set(np.round(dist.ravel(), 3).tolist())))

    ore_mask = dist > 0.08
    print(f"ore texels: {int(ore_mask.sum())} of {ore_mask.size}")
    r, g = rgb[..., 0], rgb[..., 1]
    print(f"ore texel r-g range: {(r-g)[ore_mask].min():.3f} to {(r-g)[ore_mask].max():.3f} "
          f"(matrix range {(r-g)[~ore_mask].min():.3f} to {(r-g)[~ore_mask].max():.3f}), an orange cast")

    tolerance = 0.025
    labels, n = lib.segments(rgb, tolerance=tolerance)
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")

    baseline = 0.5
    crack = region_lum < 0.235
    face = region_lum > 0.32
    clo, chi = region_lum[crack].min(), region_lum[crack].max()
    flo, fhi = region_lum[face].min(), region_lum[face].max()
    target = np.where(crack,
            0.30 - 0.20 * (region_lum - clo) / max(chi - clo, 1e-6),
            np.where(face,
                    0.62 + 0.20 * (region_lum - flo) / max(fhi - flo, 1e-6),
                    baseline))

    labels_hi = lib.warp_labels(labels)
    edges = lib.region_edges(labels_hi)
    max_dist = 2
    dist_hi = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist_hi / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    bedding = blur_x(lib.fbm(lib.SIZE, base_cells=8, octaves=2, seed=71), 18)
    grain = lib.fbm(lib.SIZE, base_cells=34, octaves=3, seed=72, gain=0.55) * 0.04
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=73), 1) * 0.03
    matrix_height = layout + bedding * 0.05 + grain + pores

    ore_rgb = np.repeat(ore_mask[..., None].astype(np.float32), 3, axis=-1)
    ore_labels, ore_n = lib.segments(ore_rgb, tolerance=0.5)
    ore_region_is_ore = np.array([bool(ore_mask[ore_labels == i].any()) for i in range(ore_n)])
    ore_sizes = np.bincount(ore_labels.ravel())
    print(f"ore clusters: {int(ore_region_is_ore.sum())} regions, sizes "
          f"{sorted(ore_sizes[ore_region_is_ore].tolist(), reverse=True)}")

    ore_labels_hi = lib.warp_labels(ore_labels, amp=8.0, seed=181)
    ore_present_hi = ore_region_is_ore[ore_labels_hi]
    ore_edges = lib.region_edges(ore_labels_hi)
    ore_max_dist = 7
    ore_dist = lib.distance_to_edge(ore_edges, max_dist=ore_max_dist)
    ore_t = np.clip(ore_dist / ore_max_dist, 0.0, 1.0)
    ore_t = ore_t * ore_t * (3 - 2 * ore_t)
    ore_t = np.where(ore_present_hi, ore_t, 0.0)

    # Rounded nugget, the same treatment as gold: smooth low frequency
    # bumps, no posterising, no fine rust grit (that belongs to iron).
    bump = lib.fbm(lib.SIZE, base_cells=16, octaves=3, seed=182, gain=0.6) * 0.06
    ore_height = 0.86 + bump

    height = matrix_height * (1 - ore_t) + ore_height * ore_t
    height = lib.normalise01(height, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(lib.SIZE, base_cells=22, octaves=3, seed=74)
    smooth = 0.6 * height + 0.45 * rough_noise + ore_t * 0.35
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 42
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
