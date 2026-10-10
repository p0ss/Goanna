"""Hand authored height and smoothness for kythen_mitteleuropa_forest_loam.

The 32 px art has four shades in a fragmented dither (segments at
tolerance 0.05: 119 regions, 60 of them a single texel, none dominant),
the same reading default_dirt.py gives its own art: small clods and litter
in a loose crumb of soil, so this follows that script's own region to
crown recipe. The region domes alone left the ambient occlusion at 0.4 to
0.7 whatever the band or strength, the same trap beaten_clay and alluvium
hit: the crown fade is too gradual a wall for the horizon based occlusion
to see. A second, sharper layer, a sparse native scale mask warped but
never blurred, stands in for the litter itself, the twigs and leaf
fragments that actually make the small dark gaps this soil needs.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_forest_loam"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("class:", CLS)

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance} "
          f"{int((sizes == 1).sum())} of {n} regions are a single texel")

    lo, hi = region_lum.min(), region_lum.max()
    target = 0.15 + 0.65 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels)
    edges = lib.region_edges(labels_hi)
    max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    crown = narrow + 1.1 * (narrow - wide)

    lumps = lib.fbm(SIZE, base_cells=10, octaves=3, seed=881, gain=0.55) * 0.30
    grit = lib.blur(lib.white_noise(SIZE, seed=882), 1) * 0.05
    pits = lib.blur(lib.white_noise(SIZE, seed=883), 2) * 0.04

    crown_field = lib.normalise01(crown + lumps + grit + pits, 0.5, 99.5)
    crown_band_hw = 0.24
    crown_field = lib.band(crown_field, crown_band_hw)

    # The litter: sparse fallen twig and leaf fragments, sharp walled so
    # the ao registers them.
    rng = np.random.default_rng(885)
    litter_native = (rng.uniform(0.0, 1.0, (src.shape[0], src.shape[0])) < 0.08).astype(int)
    litter = lib.warp_labels(litter_native, amp=1.5, seed=885).astype(np.float32)
    print(f"litter fraction {litter.mean():.3f}")

    litter_depth = 0.5
    height = np.clip(crown_field - litter * litter_depth, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=884, gain=0.55)
    smooth = 0.45 * t + 0.55 * variation - 0.10 * litter
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 16.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength} crown_band_hw={crown_band_hw} litter_depth={litter_depth}")
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
