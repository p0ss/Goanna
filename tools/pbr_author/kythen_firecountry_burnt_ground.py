"""Hand authored height and smoothness for kythen_firecountry_burnt_ground.

The 32 px art is nearly a per texel dither, luminance 0.089 to 0.118, a
span of only 0.029, the flattest source in this batch. lib.segments at
0.05 and 0.08 both collapse to one blob; only at 0.03 does it find real
structure, 101 regions, one big matrix of 456 texels and a scatter of
smaller patches from 17 to 80 texels. That reads as the brief describes:
a fine ash bed (the matrix, and the per texel dither on top of it) with
charred wood fragments sitting in and on it (the patches), matte all
over. The fragments are read as slightly proud chunks with a rough,
occluding edge where ash has drifted up against them, rather than as
pits, since charcoal breaks into real lumps that sit above the fine ash
around them.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_burnt_ground"
CLS = "soil"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")

    for tolerance in (0.03, 0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = np.bincount(labels.ravel())
        print(f"segments at tolerance {tolerance}: n={n} biggest={int(sizes.max())}")

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"using tolerance {tolerance}: n={n}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])

    # The matrix (the biggest region, fine ash) sits at the baseline; the
    # smaller patches are charcoal fragments, proud of it, brighter
    # fragments the drier, more broken up ash-dusted chips and darker
    # fragments the denser lumps of char.
    matrix_id = int(np.argmax(sizes))
    is_matrix = np.arange(n) == matrix_id
    print(f"matrix region {matrix_id}, {int(sizes[matrix_id])} texels")
    lo, hi = region_lum[~is_matrix].min(), region_lum[~is_matrix].max()
    target = np.where(is_matrix, 0.30,
            0.50 + 0.30 * (region_lum - lo) / max(hi - lo, 1e-6))

    labels_hi = lib.warp_labels(labels, amp=5.0, seed=91)
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # a charcoal chunk is a handful of texels, rounded rather than an outlined chip
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = target[labels_hi] * t + 0.30 * (1.0 - t)

    # Below the texel: fine ash grain everywhere, and a scatter of small
    # dark pits where ash has settled into a hollow between fragments,
    # which is what earns the jointed ao_min rule.
    grain = lib.fbm(SIZE, base_cells=50, octaves=3, seed=92, gain=0.55) * 0.10
    pits = lib.blur(lib.white_noise(SIZE, seed=93), 1)
    pit_cut = float(np.percentile(pits, 22))
    pits = np.where(pits < pit_cut, pits - pit_cut, 0.0) * 1.6

    height = lib.normalise01(layout + grain + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: matte throughout, ash duller than char, both well below
    # the class level, with the fragments' own variation riding on top.
    variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=94, gain=0.55)
    smooth = 0.35 * (height - height.mean()) + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 11.5
    height = lib.band(height, 0.40)
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
