"""Hand authored LabPBR height and smoothness for kythen_stone.

The 16 px art is a mottled grey, luminance 0.424 to 0.533, mean 0.481, sd
0.033. There is no cobble style layout of separate stones and no drawn
groove anywhere in the tile; it is one continuous slab and the flecks are
pitting and grain in that one surface, the same reading default_stone.py
uses for Mineclonia's stone. Segmenting at tolerance 0.02 finds 102 small
flecks, none dominant (largest 20 of 256 texels), which is the true grain
of this art: lots of tiny flecks, not a handful of big regions and not one
giant blob (0.03 already collapses half the tile into one 122 texel patch).
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")

    tolerance = 0.02
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])

    # Target height per fleck, the same rule default_stone.py uses: only
    # the flecks clearly darker or lighter than the matrix are cut down or
    # raised, everything in between stays the untouched matrix, so the
    # depth is not spread thin over every one of the 102 flecks.
    baseline = 0.5
    lo, hi = region_lum.min(), region_lum.max()
    pit = region_lum < (lo + 0.35 * (hi - lo))
    grain_mask = region_lum > (lo + 0.65 * (hi - lo))
    print(f"pit flecks: {int(pit.sum())}, grain flecks: {int(grain_mask.sum())}, "
          f"matrix flecks: {int(n - pit.sum() - grain_mask.sum())}")
    target = np.where(pit, 0.30, np.where(grain_mask, 0.70, baseline))

    labels_hi = lib.warp_labels(labels, size=lib.SIZE)
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # soft mounds and dishes, not outlined pieces
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # Sub texel structure: fine mineral grain and sparser pores, both well
    # below the layout's own scale.
    grain = lib.fbm(lib.SIZE, base_cells=40, octaves=3, seed=201, gain=0.55) * 0.04
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=202), 1) * 0.05
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: pits gather dust and stay rough, raised
    # grain is what wears smooth, with the stone's own patchy variation
    # riding on top. pack() moves the mean to the class level.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=203)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 55
    # Held in a band scaled to the surface's real depth: full range domes
    # read as rubble under a grazing lamp, and this slab has no joints.
    height = lib.band(height, 0.16)
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
