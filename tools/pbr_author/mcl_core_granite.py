"""Hand authored LabPBR height and smoothness for mcl_core_granite.

The 16 px art is nine shades of a warm pink brown, lum 0.369 to 0.606, sd
0.063. There is no cobble style layout of separate stones: it is granite,
almost entirely interlocking crystal grains, and the shades read as three
groups. The middle three (0.488, 0.500, 0.515, the last of those the single
most common shade in the art at 86 texels) are the matte matrix between
grains. The four darkest (0.369 to 0.448, 70 texels) are dark mineral
grains, biotite and hornblende. The two lightest (0.556, 0.606, 69 texels)
are the pale quartz and feldspar grains that catch the light. Granite has
no true binder, so both grain colours stand a little proud of the matrix
rather than one of them sinking into it, and granite is the coarsest
grained of the three crystalline stones in this set (diorite, andesite),
so its grains keep the widest taper of the three.
"""
import sys

import numpy as np

import lib

STEM = "mcl_core_granite"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    # Connected regions of near identical colour. 0.03 keeps a grain's own
    # texels together without bridging one grain colour to the next: 127
    # regions, most one to nine texels. That is granite's real grain, lots
    # of small crystal faces, not a handful of large stones.
    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    # Target height per grain: the matrix band (0.47 to 0.53) is the matte
    # ground the grains sit in and stays lowest; both the dark mineral
    # grains and the pale quartz and feldspar grains stand proud of it, the
    # pale ones a little higher because they are the ones that actually
    # sparkle.
    baseline = 0.45
    dark_grain = region_lum < 0.47
    light_grain = region_lum > 0.53
    matrix = ~dark_grain & ~light_grain
    print(f"dark grains: {int(dark_grain.sum())}, light grains: "
          f"{int(light_grain.sum())}, matrix: {int(matrix.sum())} of {n}")
    target = np.where(dark_grain, 0.62, np.where(light_grain, 0.82, baseline))

    labels_hi = lib.warp_labels(labels)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # grains run one to nine texels, the coarsest taper of the three crystalline stones
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: rounds a square grain into a domed crystal face
    layout = baseline + (target[labels_hi] - baseline) * t

    # Sub texel structure: coarse crystal sparkle a few texels across, and a
    # finer scatter of grain boundary pores underneath it.
    sparkle = lib.fbm(lib.SIZE, base_cells=22, octaves=3, seed=41, gain=0.55) * 0.07
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=42), 1) * 0.04
    height = lib.normalise01(layout + sparkle + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the matte matrix stays rough, the proud
    # crystal faces are what catches a polish. Granite's own patchy
    # variation rides on top; pack() moves the mean, we owe the spread.
    rough_noise = lib.fbm(lib.SIZE, base_cells=18, octaves=3, seed=43)
    smooth = 0.55 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the grain edges the height field lines up with.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 22
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
