"""Hand authored LabPBR height and smoothness for mcl_core_iron_ore.

The 16 px art's grey texels are default_stone's own palette pixel for
pixel: every texel that is not iron sits at zero distance (max absolute
channel difference) from one of default_stone's six colours. Fifty texels
sit further out, 0.07 to 0.33 away, a clean gap above the zero of the
matrix, and they carry a warm rust cast (r above g above b) beyond what the
matrix's own natural warm tint reaches. Those are the iron: a rounded,
pitted nodule, not a crystal, rusty and rough rather than sharp.
"""
import sys

import numpy as np

import lib

STEM = "mcl_core_iron_ore"
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

    ore_mask = dist > 0.04  # clean gap: matrix sits at 0.0, iron's nearest shade is 0.07 out
    print(f"ore texels: {int(ore_mask.sum())} of {ore_mask.size}")
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    print(f"ore texel r-b range: {(r-b)[ore_mask].min():.3f} to {(r-b)[ore_mask].max():.3f} "
          f"(matrix range {(r-b)[~ore_mask].min():.3f} to {(r-b)[~ore_mask].max():.3f}), a warm rust cast")

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
    max_dist = 2
    dist_hi = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist_hi / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    matrix_layout = baseline + (target[labels_hi] - baseline) * t

    grain = lib.fbm(lib.SIZE, base_cells=40, octaves=3, seed=11, gain=0.55) * 0.04
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=12), 1) * 0.05
    matrix_height = matrix_layout + grain + pores

    # --- the ore, connected components of the rust mask --------------------
    ore_rgb = np.repeat(ore_mask[..., None].astype(np.float32), 3, axis=-1)
    ore_labels, ore_n = lib.segments(ore_rgb, tolerance=0.5)
    ore_region_is_ore = np.array([bool(ore_mask[ore_labels == i].any()) for i in range(ore_n)])
    ore_sizes = np.bincount(ore_labels.ravel())
    print(f"ore clusters: {int(ore_region_is_ore.sum())} regions, sizes "
          f"{sorted(ore_sizes[ore_region_is_ore].tolist(), reverse=True)}")

    ore_labels_hi = lib.warp_labels(ore_labels, amp=8.0, seed=41)
    ore_present_hi = ore_region_is_ore[ore_labels_hi]
    ore_edges = lib.region_edges(ore_labels_hi)
    ore_max_dist = 6  # wide taper: a nodule bulges out of the rock, it does not stop sharply
    ore_dist = lib.distance_to_edge(ore_edges, max_dist=ore_max_dist)
    ore_t = np.clip(ore_dist / ore_max_dist, 0.0, 1.0)
    ore_t = ore_t * ore_t * (3 - 2 * ore_t)
    ore_t = np.where(ore_present_hi, ore_t, 0.0)

    # Rounded, not faceted: a low frequency bump for the nodule's own
    # shape, with a coarser, higher amplitude grit on top than the plain
    # stone's own pores, because rust pits deeper than clean rock does.
    bump = lib.fbm(lib.SIZE, base_cells=14, octaves=2, seed=42, gain=0.5) * 0.05
    grit = lib.blur(lib.white_noise(lib.SIZE, seed=43), 1) * 0.09
    ore_height = 0.87 + bump + grit

    height = matrix_height * (1 - ore_t) + ore_height * ore_t
    height = lib.normalise01(height, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Native iron is a metal: the nugget itself gets metal_mask, so the
    # shader reflects the sky through the albedo colour there, and its own
    # smoothness is set high, with a little of its own rust grit rather
    # than a mirror. pack() moves the mean of the WHOLE image onto the
    # stone class level, so the matrix component is recentred to zero
    # before the nugget is dropped in: that leaves the shift room to carry
    # the nugget up near 0.85 to 0.9 instead of the boost being swallowed
    # by the matrix's own share of the mean.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=13)
    matrix_smooth = 0.5 * height + 0.55 * rough_noise
    matrix_smooth = matrix_smooth - matrix_smooth[~ore_present_hi].mean()
    ore_smooth = 0.99 + bump * 0.2 - grit * 0.3
    smooth = np.where(ore_present_hi, ore_smooth, matrix_smooth)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 38
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, metal_mask=ore_present_hi)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    for line in lib.check(m, CLS):
        print(line)
    s_back = np.asarray(lib.Image.open(str(out_dir) + "/" + STEM + "_s.png").convert("RGBA")).astype(np.float32) / 255.0
    print(f"ore texel smoothness after packing: mean {s_back[..., 0][ore_present_hi].mean():.3f} "
          f"(want 0.85 to 0.90), metal G mean {s_back[..., 1][ore_present_hi].mean():.3f} (want 1.0)")
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")


if __name__ == "__main__":
    main()
