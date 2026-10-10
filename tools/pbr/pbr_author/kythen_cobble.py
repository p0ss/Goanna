"""Hand authored height and smoothness for kythen_cobble.

The 16 px art is not a scatter of small pebbles: it is a thick, continuous
mortar lattice (one darkest shade, 0.306, forming a single connected region
of 136 of the 256 texels at every tolerance up to 0.08) enclosing six
paving stones, three rows of two, each 18 to 36 texels. Inside each stone
the remaining five to six shades are the stone's own shading, sunlit edge
to shadowed corner, not further joints; segmenting at 0.08 keeps the six
stones apart and each whole. class_of reads this stem back as "gravel",
narrowly closer to the bake's own smoothness level than "stone" is; kept,
since the check targets stone, gravel and cobble the same tilt band anyway
and this is what the bake decided.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_cobble"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    # 0.08 is wide enough to weld each stone's own shading together (all
    # under 0.08 apart) while the mortar, 0.09 to 0.17 below the nearest
    # stone shade, still cuts clean: seven regions, mortar plus six stones.
    tolerance = 0.08
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    mortar = region_lum < 0.34
    print(f"mortar regions: {int(mortar.sum())} of {n}, {int(sizes[mortar].sum())} texels of 256")

    lo, hi = region_lum[~mortar].min(), region_lum[~mortar].max()
    target = np.where(mortar, 0.05, 0.55 + 0.35 * (region_lum - lo) / max(hi - lo, 1e-6))

    labels_hi = lib.warp_labels(labels)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # groove half width; a wider taper never reached the stone tilt band
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = target[labels_hi] * t

    # The dome taper saturates in the middle of the bigger stones, leaving
    # a flat crown; a slow bulge per stone rounds that off.
    crown = lib.fbm(SIZE, base_cells=6, octaves=2, seed=61) * 0.05
    layout = layout + crown * t

    grain = lib.fbm(SIZE, base_cells=32, octaves=3, seed=62, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=63), 1) * 0.05
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=16, octaves=3, seed=64)
    smooth = 0.55 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 55
    height = lib.band(height, 0.7)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    for line in lib.check(m, cls):
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")


if __name__ == "__main__":
    main()
