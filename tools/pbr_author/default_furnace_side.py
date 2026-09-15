"""Hand authored LabPBR height and smoothness for default_furnace_side.

The art is a rough grey cobble face, nine shades running 0.263 to 0.681 in
even steps of about 0.04 to 0.05: unlike default_cobble there is no single
wide gap marking a mortar shade apart from the stone (default_cobble's
mortar sits 0.068 below its lightest stone shade with every other step
under 0.043; here the largest gap between neighbouring shades is 0.036, no
bigger than several others). So this is one continuous rough stone, no
separate mortar material, built the same segment, warp, dome way as
default_cobble regardless: segmenting at tolerance 0.06 gives 44 regions,
from a 74 texel field down to single texels, and the darkest quarter of
them by mean brightness stand in for the mortar a cobble face always has
between its stones, low targets rather than a shade apart.
"""
import sys

import numpy as np

import lib

STEM = "default_furnace_side"
CLS = "stone"
SIZE = lib.SIZE
SEG_TOLERANCE = 0.06


def build_body(stem, src, seed_base):
    """The cobble stone body: returns (height, smooth, region info) so the
    front script can reuse it and cut its opening into the same body."""
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{stem}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    labels, n = lib.segments(rgb, tolerance=SEG_TOLERANCE)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={SEG_TOLERANCE}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:12])

    # No natural mortar gap (see docstring), so the darkest quarter of the
    # regions, weighted by how much of the face they cover, stand in for it.
    order = np.argsort(region_lum)
    covered = 0
    mortar = np.zeros(n, dtype=bool)
    total = sizes.sum()
    for i in order:
        if covered >= total * 0.22:
            break
        mortar[i] = True
        covered += sizes[i]
    print(f"mortar-equivalent regions: {int(mortar.sum())} of {n}, "
          f"{int(sizes[mortar].sum())} texels of 256")

    lo, hi = region_lum[~mortar].min(), region_lum[~mortar].max()
    target = np.where(mortar, 0.08, 0.55 + 0.35 * (region_lum - lo) / max(hi - lo, 1e-6))

    labels_hi = lib.warp_labels(labels, seed=61 + seed_base)
    edges = lib.region_edges(labels_hi)
    max_dist = 5
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = target[labels_hi] * t

    crown = lib.fbm(SIZE, base_cells=4, octaves=2, seed=62 + seed_base) * 0.05
    layout = layout + crown * t

    grain = lib.fbm(SIZE, base_cells=32, octaves=3, seed=63 + seed_base, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=64 + seed_base), 1) * 0.05
    height = layout + grain + pores

    rough_noise = lib.fbm(SIZE, base_cells=16, octaves=3, seed=65 + seed_base)
    smooth = 0.55 * lib.normalise01(height, 0.5, 99.5) + 0.55 * rough_noise
    return height, smooth


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    height, smooth = build_body(STEM, src, seed_base=0)
    height = lib.normalise01(height, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 14
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
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
