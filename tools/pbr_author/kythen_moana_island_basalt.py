"""Hand authored height and smoothness for kythen_moana_island_basalt.

The 32 px art is a dark, low saturation dither, luminance 0.190 to 0.292,
mean 0.249, sd 0.038, with no drawn stones or joints: lib.segments finds
only small flecks throughout (95 regions at tolerance 0.05, biggest 142
texels), the fine mottle of an aphanitic rock rather than cobble's separate
stones, the same reading kythen_firecountry_basalt.py gives Firecountry's
own basalt. Greenness is negligible here (max 0.012, no lichen the way
kythen_moana_lava_lichen carries), a plain dark vesicular rock. class_of
reads back cloth, plainly wrong for a lava rock with no bake data of its
own to read; this script uses stone, matching firecountry_basalt.py's own
override. Built the same way: only the darkest fraction of flecks reads as
a vesicle, cut to a shallow dimple floor, everything else stays close to
the matrix level with fine sub texel grain.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_island_basalt"
CLS = "stone"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    greenness = rgb[..., 1] - (rgb[..., 0] + rgb[..., 2]) / 2.0
    print(f"greenness max {greenness.max():.3f} (negligible, no lichen)")
    print(f"class_of reads: {lib.class_of(STEM, GAME)}; used here: {CLS} "
          "(a dark lava rock, class_of has no bake data to read for this stem)")

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])

    # A quarter of the flecks read as vesicles, the same fraction
    # firecountry_basalt.py settled on: fewer and the map's own mean tilt
    # falls well short of a real rock's.
    cut = np.percentile(region_lum, 25)
    vesicle = region_lum < cut
    print(f"vesicle flecks: {int(vesicle.sum())} of {n} ({100.0 * vesicle.sum() / n:.0f}%)")
    baseline = 0.55
    target = np.where(vesicle, 0.04, baseline)

    labels_hi = lib.warp_labels(labels, amp=3.0, seed=901)
    edges = lib.region_edges(labels_hi)
    max_dist = 5  # a vesicle is a small round hole, deep enough to occlude
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # Fine grain: an aphanitic rock's crystals are too small to see
    # individually, so this is a dense, fine dither, but strong enough that
    # the unbroken matrix between vesicles still has real texel scale
    # relief of its own.
    grain = lib.fbm(SIZE, base_cells=60, octaves=3, seed=902, gain=0.5) * 0.12
    pores = lib.blur(lib.white_noise(SIZE, seed=903), 1) * 0.10
    # A few genuinely deep vesicles among the ordinary shallow ones, the
    # low percentile cut kythen_habesha_aksumite_ashlar.py uses for its own
    # real deep pit: the horizon based ambient occlusion needs a wall
    # steeper than the broad vesicle taper alone gives it.
    deep_field = lib.blur(lib.white_noise(SIZE, seed=905), 1)
    deep_cut = float(np.percentile(deep_field, 2.0))
    deep_vesicle = np.where(deep_field < deep_cut, (deep_field - deep_cut) * 7.0, 0.0)
    height = lib.normalise01(layout + grain + pores + deep_vesicle, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=26, octaves=3, seed=904, gain=0.55)
    smooth = 0.4 * height + 0.6 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 24
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
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
