"""Hand authored LabPBR height and smoothness for mcl_core_emerald_ore.

The 16 px art's grey texels are default_stone's own palette pixel for
pixel, zero distance from one of its six colours, everywhere outside one
compact clump around rows 3 to 11, columns 4 to 10. Distance to that
palette has a clean gap at 0.113 to 0.259: below it are anti-aliased edge
texels blending grey into green, above it is the emerald proper, with a
green cast (g above r by up to 0.49, against the matrix's own -0.05 to
-0.02) far past anything in the plain rock. Real emerald grows as
elongated hexagonal prisms, so its facets are stretched one way rather
than the rounder shape lapis and diamond use.
"""
import sys

import numpy as np

import lib

STEM = "mcl_core_emerald_ore"
CLS = "stone"  # lib.class_of(STEM) reads "stone"


def blur_x(field, radius):
    """Wrapped box blur along columns only, borrowed from mcl_deepslate.py:
    stretches emerald's facet noise into the mineral's own elongated
    prism habit without rounding it off in the other axis."""
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
    print(f"lib.class_of reads: {lib.class_of(STEM)}")
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    stone_pal = np.array(sorted(set(map(tuple,
            np.round(lib.load_source("default_stone")[..., :3].reshape(-1, 3), 3).tolist()))))
    dist = np.abs(rgb[:, :, None, :] - stone_pal[None, None, :, :]).max(axis=-1).min(axis=-1)
    print("distance to default_stone's palette:", sorted(set(np.round(dist.ravel(), 3).tolist())))

    ore_mask = dist > 0.15  # the gap between the anti-aliased fringe (<=0.113) and the emerald proper (>=0.259)
    print(f"ore texels: {int(ore_mask.sum())} of {ore_mask.size}")
    r, g = rgb[..., 0], rgb[..., 1]
    print(f"ore texel g-r range: {(g-r)[ore_mask].min():.3f} to {(g-r)[ore_mask].max():.3f} "
          f"(matrix range {(g-r)[~ore_mask].min():.3f} to {(g-r)[~ore_mask].max():.3f}), a green cast")

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

    ore_labels_hi = lib.warp_labels(ore_labels, amp=8.0, seed=81)
    ore_present_hi = ore_region_is_ore[ore_labels_hi]
    ore_edges = lib.region_edges(ore_labels_hi)
    ore_max_dist = 6
    ore_dist = lib.distance_to_edge(ore_edges, max_dist=ore_max_dist)
    ore_t = np.clip(ore_dist / ore_max_dist, 0.0, 1.0)
    ore_t = ore_t * ore_t * (3 - 2 * ore_t)
    ore_t = np.where(ore_present_hi, ore_t, 0.0)

    # Sharp facets again, but stretched one way with blur_x, the way an
    # emerald's hexagonal prism runs long in one direction rather than
    # sitting as a rounded point the way diamond's octahedron does.
    raw = blur_x(lib.fbm(lib.SIZE, base_cells=10, octaves=2, seed=82, gain=0.5), 4)
    levels = 4.0
    facet = np.round(raw * levels) / levels * 0.09
    sparkle = lib.blur(lib.white_noise(lib.SIZE, seed=83), 1) * 0.02
    ore_height = 0.92 + facet + sparkle

    height = matrix_height * (1 - ore_t) + ore_height * ore_t
    height = lib.normalise01(height, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Emerald is not a metal: it passes f0 instead of metal_mask, the gem's
    # own dielectric reflectance at normal incidence, well above the
    # matrix's 0.04, with smoothness set high, a cut face rather than a
    # mirror texture. pack() moves the mean of the WHOLE image onto the
    # stone class level, so the matrix component is recentred well below
    # zero before the gem is dropped in: that leaves the shift room to
    # carry the gem up near 0.9 instead of the boost being swallowed by
    # the matrix's own share of the mean.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=13)
    matrix_smooth = 0.5 * height + 0.55 * rough_noise
    matrix_smooth = matrix_smooth - matrix_smooth[~ore_present_hi].mean() - 0.16
    ore_smooth = 1.10 + facet * 0.8 + sparkle * 0.2
    smooth = np.where(ore_present_hi, ore_smooth, matrix_smooth)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    f0 = np.where(ore_present_hi, 0.16, lib.DIELECTRIC_F0 / 255.0)

    albedo = lib.upscale(src[..., :3])

    normal_strength = 38
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, f0=f0)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    for line in lib.check(m, CLS):
        print(line)
    s_back = np.asarray(lib.Image.open(str(out_dir) + "/" + STEM + "_s.png").convert("RGBA")).astype(np.float32) / 255.0
    print(f"ore texel smoothness after packing: mean {s_back[..., 0][ore_present_hi].mean():.3f} "
          f"(want about 0.9), F0 byte mean {(s_back[..., 1][ore_present_hi] * 255).mean():.1f} (want about 41)")
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")


if __name__ == "__main__":
    main()
