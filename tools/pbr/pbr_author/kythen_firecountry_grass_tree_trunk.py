"""Hand authored height and smoothness for kythen_firecountry_grass_tree_trunk.

The 32 px art has one dominant matrix (lib.segments, tolerance 0.03, finds
737 of 1024 texels in a single region) with many small flecks scattered
through it, from 20 texels down to lone ones, no drawn stones and no clean
furrow: a handful of columns read nearly flat (2, 5, 20, 21, 31, standard
deviation under 0.02) but they are scattered rather than the one or two
wide channels a cut log shows, so they are read as a coincidence of this
noisy art rather than a deliberate groove. A grass tree trunk is a rough
skirt of old leaf bases, matted and shaggy, not smooth bark, so the relief
here is built as the flecks default_stone.py's own construction gives a
fine grained rock, with a vertical fibrous streak (the hanging leaf bases)
layered underneath rather than the tight radial furrows a real log gets.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_grass_tree_trunk"
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
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("col std:", np.round(lum.std(axis=0), 3).tolist())

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])

    matrix_id = int(np.argmax(sizes))
    is_matrix = np.arange(n) == matrix_id
    lo, hi = region_lum[~is_matrix].min(), region_lum[~is_matrix].max()
    target = np.where(is_matrix, 0.42,
            0.20 + 0.55 * (region_lum - lo) / max(hi - lo, 1e-6))

    labels_hi = lib.warp_labels(labels, amp=4.0, seed=331)
    edges = lib.region_edges(labels_hi)
    max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = 0.42 + (target[labels_hi] - 0.42) * t

    # Vertical fibrous streaking: the hanging skirt of old leaf bases,
    # stretched long along y, plus fine grain and a scatter of small
    # deeper pockets where the mat has frayed away from the trunk.
    fibre = blur_axis(lib.fbm(SIZE, base_cells=26, octaves=2, seed=332, gain=0.5), radius=12, axis=0) * 0.24
    grain = lib.fbm(SIZE, base_cells=44, octaves=3, seed=333, gain=0.55) * 0.06
    pocket_field = lib.blur(lib.white_noise(SIZE, seed=334), 2)
    pocket_cut = float(np.percentile(pocket_field, 30))
    pockets = np.where(pocket_field < pocket_cut, pocket_field - pocket_cut, 0.0) * 3.6

    height = lib.normalise01(layout + fibre + grain + pockets, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(lib.fbm(SIZE, base_cells=18, octaves=3, seed=335, gain=0.55), radius=8, axis=0)
    smooth = 0.45 * t + 0.5 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 16.0
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
