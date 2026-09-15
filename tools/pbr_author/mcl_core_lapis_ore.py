"""Hand authored LabPBR height and smoothness for mcl_core_lapis_ore.

The 16 px art's grey texels carry exactly default_stone's six shades,
0.389 to 0.602, the same matrix, dressed the same way: two pit shades, two
grain shades, two shades of untouched stone in between. Threaded through
that matrix are 53 texels with a real blue cast, b minus r from 0.31 to
0.49 against the grey texels' -0.08 to -0.04, in two obvious clumps: the
lapis ore. Those clumps are crystal, not paint on the stone, so they get
their own layer, standing slightly proud of the matrix around them and
smoother, the way an exposed mineral face catches the light where the
surrounding rock does not.
"""
import sys

import numpy as np

import lib

STEM = "mcl_core_lapis_ore"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    sat = rgb[..., 2] - rgb[..., 0]  # blue minus red: the ore's own colour signature, absent from the stone
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"sat (b-r) min {sat.min():.3f} max {sat.max():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    ore_mask = sat > 0.15  # clear gap: grey runs -0.08 to -0.04, ore runs 0.31 to 0.49
    print(f"ore texels: {int(ore_mask.sum())} of {ore_mask.size}")

    # --- the stone matrix, default_stone's own reading of these shades -----
    # Connected regions of near identical colour, tight enough (0.03) to
    # keep the matrix's own fine flecks distinct from each other and from
    # the ore, which differs by far more than 0.03 in the blue channel.
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

    # --- the ore, connected components of the blue mask ---------------------
    # lib.segments groups by colour distance, so recasting the boolean mask
    # as an RGB image and using a coarse tolerance gets one label per
    # connected true or false run, wrapping the way the art does, which is
    # a connected components pass without writing a second one.
    ore_rgb = np.repeat(ore_mask[..., None].astype(np.float32), 3, axis=-1)
    ore_labels, ore_n = lib.segments(ore_rgb, tolerance=0.5)
    ore_region_is_ore = np.array([bool(ore_mask[ore_labels == i].any()) for i in range(ore_n)])
    ore_sizes = np.bincount(ore_labels.ravel())
    print(f"ore clusters: {int(ore_region_is_ore.sum())} regions, sizes "
          f"{sorted(ore_sizes[ore_region_is_ore].tolist(), reverse=True)}")

    ore_labels_hi = lib.warp_labels(ore_labels, amp=8.0, seed=21)
    ore_present_hi = ore_region_is_ore[ore_labels_hi]
    ore_edges = lib.region_edges(ore_labels_hi)
    ore_max_dist = 6  # clusters, not flecks: a wide taper so a clump reads as one raised mass
    ore_dist = lib.distance_to_edge(ore_edges, max_dist=ore_max_dist)
    ore_t = np.clip(ore_dist / ore_max_dist, 0.0, 1.0)
    ore_t = ore_t * ore_t * (3 - 2 * ore_t)
    ore_t = np.where(ore_present_hi, ore_t, 0.0)  # only rises where the cluster actually is

    facet = lib.fbm(lib.SIZE, base_cells=24, octaves=3, seed=22, gain=0.5) * 0.05
    ore_height = 0.92 + facet

    height = matrix_height * (1 - ore_t) + ore_height * ore_t
    height = lib.normalise01(height, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Lapis is not a metal: it passes f0 instead of metal_mask, the crystal's
    # own dielectric reflectance at normal incidence, above the matrix's
    # 0.04, with smoothness raised, a crystal face wears smoother than the
    # rock around it, but nowhere near the cut gems' polish. pack() moves
    # the mean of the WHOLE image onto the stone class level, so the matrix
    # component is recentred to zero before the ore is dropped in: that
    # leaves the shift room to carry the ore up near 0.6 instead of the
    # boost being swallowed by the matrix's own share of the mean.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=13)
    matrix_smooth = 0.5 * height + 0.55 * rough_noise
    matrix_smooth = matrix_smooth - matrix_smooth[~ore_present_hi].mean()
    ore_smooth = 0.71 + facet * 0.5
    smooth = np.where(ore_present_hi, ore_smooth, matrix_smooth)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    f0 = np.where(ore_present_hi, 0.06, lib.DIELECTRIC_F0 / 255.0)

    # Nearest upscale keeps the matrix and ore edges the height field lines
    # up with.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 40
    # Held in a band scaled to the surface's real depth: full range
    # domes read as rubble under a grazing lamp on the ramp.
    height = lib.band(height, 0.2)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, f0=f0)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    for line in lib.check(m, CLS):
        print(line)
    s_back = np.asarray(lib.Image.open(str(out_dir) + "/" + STEM + "_s.png").convert("RGBA")).astype(np.float32) / 255.0
    print(f"ore texel smoothness after packing: mean {s_back[..., 0][ore_present_hi].mean():.3f} "
          f"(want about 0.6), F0 byte mean {(s_back[..., 1][ore_present_hi] * 255).mean():.1f} (want about 15)")
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")


if __name__ == "__main__":
    main()
