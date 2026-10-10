"""Hand authored height and smoothness for kythen_khmer_escarpment_duff.

The 32 px art is nearly two tone, 0.180, 0.185 and one lighter fleck at
0.251, and segments to almost nothing at tight tolerance (92 regions, half
of them single texels) but collapses at 0.08 to ten: one 596 texel
background (58 percent), two structural patches (259 and 105 texels) and a
scatter of small litter down to four single texel flecks. That is leaf
litter: mostly a flat duff mat, with looser piles where litter has built up
and a few bright twig or leaf flecks catching the light. Height follows
that coarse structure rather than the fine dither, held in a moderate band
so the mat reads as a soft compressible layer rather than loose stones.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_escarpment_duff"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print("class:", CLS)

    tolerance = 0.08
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    lo, hi = region_lum.min(), region_lum.max()
    target = 0.15 + 0.65 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=6.0, seed=301)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 1.1 * (narrow - wide)

    # Litter clumps a little coarser than beaten_earth's crumb, plus a
    # finer, sparser dust of individual leaf and twig flecks on top.
    lumps = lib.fbm(SIZE, base_cells=10, octaves=3, seed=302, gain=0.55) * 0.25
    grit = lib.blur(lib.white_noise(SIZE, seed=303), 1) * 0.06
    pits = lib.blur(lib.white_noise(SIZE, seed=304), 2) * 0.05

    height = lib.normalise01(layout + lumps + grit + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    band_hw = 0.5
    height = lib.band(height, band_hw)

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=305, gain=0.55)
    smooth = 0.45 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 18.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength} band_hw={band_hw}")
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
