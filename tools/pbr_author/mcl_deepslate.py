"""Hand authored LabPBR height and smoothness for mcl_deepslate.

The 16 px art is nine shades of near black grey, lum 0.177 to 0.394, sd
0.052, and it is not a mottled slab the way default_stone is: its darkest
texels cluster into runs along single rows (a run of six at row 13 columns
8 to 13, a run of four at row 7 columns 0 to 3, another at row 3 columns 4
to 7) far more than they cluster down columns (worst column run is two).
That is deepslate's bedding: cracks that run one way, horizontally across
the block face, not scattered pits. The bulk of the art (0.249 to 0.311, 58
percent) is the matte rock between beds; the brightest two shades (0.346,
0.394, 14 percent) are bedding faces that have sheared clean and catch the
light; the darkest three (0.177, 0.190, 0.221, 28 percent) are the crack
lines and their shadowed shoulders.
"""
import sys

import numpy as np

import lib

STEM = "mcl_deepslate"
CLS = "stone"


def blur_x(field, radius):
    """Wrapped box blur along columns only, to stretch a feature sideways
    without touching how tall it is. lib.blur does both axes at once, which
    would round the cracks off instead of running them along the bed."""
    if radius <= 0:
        return field
    out = field.astype(np.float32)
    k = 2 * radius + 1
    acc = np.zeros_like(out)
    for d in range(-radius, radius + 1):
        acc += np.roll(out, d, axis=1)
    return acc / k


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    dark = lum < 0.235
    print("dark texel count per row (bedding runs horizontally):",
          np.bincount(np.where(dark)[0], minlength=16).tolist())
    print("dark texel count per column:",
          np.bincount(np.where(dark)[1], minlength=16).tolist())

    # Connected regions of near identical colour. 0.025 keeps a crack's own
    # texels together across a row without bridging to the next shade: 128
    # regions. Because the art's dark texels already run along rows more
    # than columns, the regions this finds for them come out elongated the
    # same way, which is what carries the bedding direction through
    # warp_labels below.
    tolerance = 0.025
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    # Target height per region: the three darkest shades are crack, cut
    # down further the darker they are; the middle four shades are the
    # matte rock between beds and sit close to the baseline; the two
    # brightest are a sheared bedding face, raised further the brighter.
    baseline = 0.5
    crack = region_lum < 0.235
    face = region_lum > 0.32
    matrix = ~crack & ~face
    print(f"crack: {int(crack.sum())}, bedding face: {int(face.sum())}, "
          f"matrix: {int(matrix.sum())} of {n}")
    clo, chi = region_lum[crack].min(), region_lum[crack].max()
    flo, fhi = region_lum[face].min(), region_lum[face].max()
    target = np.where(crack,
            0.30 - 0.20 * (region_lum - clo) / max(chi - clo, 1e-6),
            np.where(face,
                    0.62 + 0.20 * (region_lum - flo) / max(fhi - flo, 1e-6),
                    baseline))

    labels_hi = lib.warp_labels(labels)
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # a soft shouldered crack; a tight one lit on both edges read as an edge filter
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: rounds a square crack texel into a groove
    layout = baseline + (target[labels_hi] - baseline) * t

    # Bedding structure below the texel: an isotropic noise field stretched
    # sideways with blur_x reads as thin horizontal beds the way real slate
    # cleaves, laid under the fine grain and pores every stone in this set
    # carries.
    bedding = blur_x(lib.fbm(lib.SIZE, base_cells=8, octaves=2, seed=71), 18)
    grain = lib.fbm(lib.SIZE, base_cells=34, octaves=3, seed=72, gain=0.55) * 0.04
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=73), 1) * 0.03
    height = lib.normalise01(layout + bedding * 0.05 + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the cracks gather dust and stay rough, the
    # sheared bedding faces are what reads smooth on real slate. Deepslate's
    # own patchy variation rides on top; pack() moves the mean, we owe the
    # spread.
    rough_noise = lib.fbm(lib.SIZE, base_cells=22, octaves=3, seed=74)
    smooth = 0.6 * height + 0.45 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the crack edges the height field lines up with.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 46
    # Held in a band scaled to the surface's real depth: full range
    # domes read as rubble under a grazing lamp on the ramp.
    height = lib.band(height, 0.18)
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
