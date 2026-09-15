"""Hand authored LabPBR height and smoothness for mcl_core_coal_ore.

The 16 px art's grey texels carry exactly default_stone's six shades, 0.389
to 0.602, the same matrix, dressed the same way: two pit shades, two grain
shades, two shades of untouched stone in between. Coal is the exception to
every other ore in this fleet: it is not a colour, it is a lack of one. The
image carries seven extra shades below 0.389, from 0.032 up to 0.378, all
of them grey (r minus g and g minus b sit inside the matrix's own -0.01 to
0.06 spread, no cast either way), and 0.389 itself still belongs to the
matrix's own darkest pit shade. So the ore is found by luminance alone,
below the stone's own darkest shade, with no colour test to write.
"""
import sys

import numpy as np

import lib

STEM = "mcl_core_coal_ore"
CLS = "stone"  # lib.class_of(STEM) reads "stone"; matches this family's own default_stone matrix


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    print(f"lib.class_of reads: {lib.class_of(STEM)}")
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    stone = lib.load_source("default_stone")[..., :3]
    stone_min = lib.luminance(stone).min()
    print(f"default_stone's own darkest shade: {stone_min:.3f}")

    ore_mask = lum < stone_min - 0.002  # strictly darker than any plain stone texel
    print(f"ore texels: {int(ore_mask.sum())} of {ore_mask.size}")
    print(f"ore texel r-g range: {(r-g)[ore_mask].min():.3f} to {(r-g)[ore_mask].max():.3f} "
          f"(matrix range {(r-g)[~ore_mask].min():.3f} to {(r-g)[~ore_mask].max():.3f}), no cast either way")

    # --- the stone matrix, default_stone's own reading of these shades -----
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
    max_dist = 2  # flecks are one to six texels across, same as default_stone
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    matrix_layout = baseline + (target[labels_hi] - baseline) * t

    grain = lib.fbm(lib.SIZE, base_cells=40, octaves=3, seed=11, gain=0.55) * 0.04
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=12), 1) * 0.05
    matrix_height = matrix_layout + grain + pores

    # --- the ore, connected components of the dark mask --------------------
    ore_rgb = np.repeat(ore_mask[..., None].astype(np.float32), 3, axis=-1)
    ore_labels, ore_n = lib.segments(ore_rgb, tolerance=0.5)
    ore_region_is_ore = np.array([bool(ore_mask[ore_labels == i].any()) for i in range(ore_n)])
    ore_sizes = np.bincount(ore_labels.ravel())
    print(f"ore clusters: {int(ore_region_is_ore.sum())} regions, sizes "
          f"{sorted(ore_sizes[ore_region_is_ore].tolist(), reverse=True)}")

    ore_labels_hi = lib.warp_labels(ore_labels, amp=8.0, seed=31)
    ore_present_hi = ore_region_is_ore[ore_labels_hi]
    ore_edges = lib.region_edges(ore_labels_hi)
    ore_max_dist = 6  # wide taper: a sooty patch fades into the rock, it does not stop sharply
    ore_dist = lib.distance_to_edge(ore_edges, max_dist=ore_max_dist)
    ore_t = np.clip(ore_dist / ore_max_dist, 0.0, 1.0)
    ore_t = ore_t * ore_t * (3 - 2 * ore_t)
    ore_t = np.where(ore_present_hi, ore_t, 0.0)

    # Coal does not stand proud: it is dull carbon, soft and slightly sunken
    # below the rock around it, with no facet to catch a light at all, just
    # a low soft cloud of dust noise.
    dust = lib.fbm(lib.SIZE, base_cells=18, octaves=3, seed=32, gain=0.55) * 0.04
    ore_height = 0.08 + dust

    height = matrix_height * (1 - ore_t) + ore_height * ore_t
    height = lib.normalise01(height, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height on the stone; the coal patch is matte and
    # collects dust in its own recess, so it goes rougher again, not
    # smoother, the only ore in the fleet that does.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=13)
    smooth = 0.5 * height + 0.55 * rough_noise - ore_t * 0.18
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 40
    # Held in a band scaled to the surface's real depth: full range
    # domes read as rubble under a grazing lamp on the ramp.
    height = lib.band(height, 0.2)
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
