"""Hand authored LabPBR height and smoothness for mcl_core_andesite.

The 16 px art is seven shades of grey green, lum 0.338 to 0.549, sd 0.053,
the tightest lum spread and the tightest colour cluster of the three
crystalline stones: andesite is the fine grained one, the rock a lava
cools quickly into, so its crystals never grow large. 61 percent of the art
(0.402, 0.415, 0.442) sits in one narrow matrix band; the darker tail
(0.338, 0.364, 57 texels) is fine dark mineral, the lighter tail (0.508,
0.549, 43 texels) is pale feldspar sparkle. As with granite and diorite
both fleck colours stand a little proud of the matte matrix; here the taper
is the tightest of the three, so no grain reads larger than a couple of
texels.
"""
import sys

import numpy as np

import lib

STEM = "mcl_core_andesite"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    # Connected regions of near identical colour. 0.02 is the tightest
    # tolerance of the three crystalline stones, because andesite's own
    # shades sit closer together than granite's or diorite's: 106 regions,
    # most one to eight texels, the fine grain the rock is known for.
    tolerance = 0.02
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    # Target height per fleck: the narrow 0.39 to 0.49 band is the matte
    # matrix and stays lowest; the dark mineral flecks and the pale
    # feldspar flecks both stand proud of it, the feldspar higher because
    # it is what catches a highlight.
    baseline = 0.45
    dark_fleck = region_lum < 0.39
    light_fleck = region_lum > 0.49
    matrix = ~dark_fleck & ~light_fleck
    print(f"dark flecks: {int(dark_fleck.sum())}, light flecks: "
          f"{int(light_fleck.sum())}, matrix: {int(matrix.sum())} of {n}")
    target = np.where(dark_fleck, 0.60, np.where(light_fleck, 0.80, baseline))

    labels_hi = lib.warp_labels(labels)
    edges = lib.region_edges(labels_hi)
    max_dist = 1  # the tightest taper of the three crystalline stones, andesite's crystals never grow large
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: rounds a square fleck into a small domed crystal face
    layout = baseline + (target[labels_hi] - baseline) * t

    # Sub texel structure: fine mineral grain, finer scaled than granite's
    # or diorite's, and a fine scatter of pores under it.
    grain = lib.fbm(lib.SIZE, base_cells=46, octaves=3, seed=61, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=62), 1) * 0.05
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the matrix stays matte, the proud flecks
    # are what a polish catches. Andesite's own fine variation rides on
    # top; pack() moves the mean, we owe the spread.
    rough_noise = lib.fbm(lib.SIZE, base_cells=26, octaves=3, seed=63)
    smooth = 0.55 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the fleck edges the height field lines up with.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 25
    # Held in a band scaled to the surface's real depth: full range
    # domes read as rubble under a grazing lamp on the ramp.
    height = lib.band(height, 0.15)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    for line in lib.check(m, CLS):
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")


if __name__ == "__main__":
    main()
