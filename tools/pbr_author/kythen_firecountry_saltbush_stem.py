"""Hand authored height and smoothness for kythen_firecountry_saltbush_stem.

Checked and this art is fully opaque too, not a cut-out (alpha is 255
everywhere). It is a woody twig texture, moderate saturation (mean 0.10,
up to 0.20), with many columns reading nearly flat (3, 4, 9, 10, 11, 16,
17, 18, 21, 23, 28, 29, 30 all under 0.012 standard deviation) scattered
through the tile rather than the one or two wide channels a cut log
shows, closer to bark_sheet's or grass_tree_trunk's own noisy dither than
a clean drawn furrow. lib.segments (tolerance 0.03) finds 179 real
regions, small nodes and bark flecks along the stem. The relief follows
grass_tree_trunk.py's own device, fleck domes from those regions plus
longitudinal fibre grain, since a slender stem's own grain runs its
length the same way a trunk's bark does.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_saltbush_stem"
CLS = "wood"
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    alpha = src[..., 3]
    print("alpha min/max:", float(alpha.min()), float(alpha.max()), "(fully opaque, not a cut-out)")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])

    matrix_id = int(np.argmax(sizes))
    is_matrix = np.arange(n) == matrix_id
    lo, hi = region_lum[~is_matrix].min(), region_lum[~is_matrix].max()
    target = np.where(is_matrix, 0.44,
            0.18 + 0.55 * (region_lum - lo) / max(hi - lo, 1e-6))

    labels_hi = lib.warp_labels(labels, amp=3.5, seed=351)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = 0.44 + (target[labels_hi] - 0.44) * t

    fibre = blur_axis(lib.fbm(SIZE, base_cells=24, octaves=2, seed=352, gain=0.5), radius=12, axis=0) * 0.22
    grain = lib.fbm(SIZE, base_cells=46, octaves=3, seed=353, gain=0.55) * 0.06
    pocket_field = lib.blur(lib.white_noise(SIZE, seed=354), 2)
    pocket_cut = float(np.percentile(pocket_field, 30))
    pockets = np.where(pocket_field < pocket_cut, pocket_field - pocket_cut, 0.0) * 3.6

    height = lib.normalise01(layout + fibre + grain + pockets, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(lib.fbm(SIZE, base_cells=18, octaves=3, seed=355, gain=0.55), radius=8, axis=0)
    smooth = 0.45 * t + 0.5 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 14.5
    height = lib.band(height, 0.48)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
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
