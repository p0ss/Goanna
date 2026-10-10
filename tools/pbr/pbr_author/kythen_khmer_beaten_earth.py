"""Hand authored height and smoothness for kythen_khmer_beaten_earth.

The 32 px art is four grey shades (0.315, 0.342, 0.461, 0.461 rounded),
segmenting at any tolerance from 0.02 to 0.08 into the same 157 regions: one
dominant 298 texel patch of the commonest shade (29 percent of the tile)
plus a scatter of small and mid sized patches and 74 single texel flecks.
That reads as a compacted path: mostly one flat trodden surface, with worn
lighter patches and small darker crumbs breaking it up rather than a loose
crumb of separate clods. Height follows region brightness the way
default_dirt.py does, but held in a wider band than dirt's own 0.22 (that
combination measured tilt 11 deg, ao_min 0.68, both short of target): a
compacted surface still needs enough real drop at the worn patch edges for
the ambient occlusion to read, so this keeps roughly half the class depth
in play (band 0.5) rather than dirt's tighter crumb.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_beaten_earth"
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

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:12], "...")
    print(f"{int((sizes == 1).sum())} of {n} regions are a single texel")

    lo, hi = region_lum.min(), region_lum.max()
    target = 0.15 + 0.65 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=5.0, seed=11)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 1.1 * (narrow - wide)

    lumps = lib.fbm(SIZE, base_cells=10, octaves=3, seed=21, gain=0.55) * 0.30
    grit = lib.blur(lib.white_noise(SIZE, seed=22), 1) * 0.05
    pits = lib.blur(lib.white_noise(SIZE, seed=23), 2) * 0.04

    height = lib.normalise01(layout + lumps + grit + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Held in a band about half the class depth: wide enough that the worn
    # patch edges still give the ambient occlusion something to catch, but
    # nowhere near a cobble's full range on a surface that is beaten flat.
    band_hw = 0.5
    height = lib.band(height, band_hw)

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=24, gain=0.55)
    smooth = 0.45 * t + 0.55 * variation
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
