"""Hand authored height and smoothness for kythen_khmer_bunded_soil.

The 32 px art has six grey shades. Segmenting at tolerance 0.05 gives 96
regions: one 556 texel background (54 percent) plus real clumps from 16 to
65 texels, and 50 single texel flecks. That is a paddy bund: a raised ridge
of piled, worked soil with wet clods standing on it, not the loose crumb of
default_dirt. Height follows region brightness the same way, but the clods
need real depth to read as clumps rather than a beaten path, so this uses a
much wider band than beaten_earth's 0.5 (0.8 of the class depth) and a
higher normal_strength; the wet clod tops also get a touch more smoothness
than the dry matrix, since standing water and mud gives a slight sheen a
dry crumb does not have.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_bunded_soil"
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

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:12], "...")

    lo, hi = region_lum.min(), region_lum.max()
    target = 0.15 + 0.65 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=6.0, seed=201)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 1.1 * (narrow - wide)

    lumps = lib.fbm(SIZE, base_cells=10, octaves=3, seed=202, gain=0.55) * 0.35
    grit = lib.blur(lib.white_noise(SIZE, seed=203), 1) * 0.05
    pits = lib.blur(lib.white_noise(SIZE, seed=204), 2) * 0.04

    height = lib.normalise01(layout + lumps + grit + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # A bund's clods are real, standing lumps, not a shallow crumb, so this
    # keeps most of the class depth rather than beaten_earth's half share.
    band_hw = 0.8
    height = lib.band(height, band_hw)

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=205, gain=0.55)
    smooth = 0.45 * t + 0.55 * variation
    # A clod proud of the matrix (high t, the worn top) sitting on wet
    # ground catches a slight sheen; pack() keeps the class mean, this only
    # adds spread on top of the ordinary worn-top smoothing.
    smooth = smooth + 0.10 * t * (region_lum[labels_hi] > np.median(region_lum))
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 12.0
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
