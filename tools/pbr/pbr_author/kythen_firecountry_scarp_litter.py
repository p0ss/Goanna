"""Hand authored height and smoothness for kythen_firecountry_scarp_litter.

The 32 px art is two large patches, not a fine dither: lib.segments finds
the same 58 regions at every tolerance tried, one of 564 texels and one of
325, together 87 percent of the tile, with only a sprinkle of small
regions between them. That is a scatter of leaf litter over a scarp face,
patches of duller, more shadowed litter against brighter, drier litter,
each patch built of overlapping flakes rather than the two regions
themselves being domed as if they were single stones. Anisotropic flake
noise, short streaks at scattered angles the size of a real leaf, is
layered on the two-region base so the litter still reads as many small
flat flakes rather than two big lumps.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_scarp_litter"
CLS = "soil"
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def flake_noise(size, seed):
    """Short streaks at two crossing angles, standing in for many small
    overlapping flat leaf flakes rather than one texture direction."""
    a = blur_axis(lib.white_noise(size, seed), 4, axis=1)
    b = blur_axis(lib.white_noise(size, seed + 1), 4, axis=0)
    return 0.5 * a + 0.5 * b


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:10])

    lo, hi = region_lum.min(), region_lum.max()
    target = 0.35 + 0.35 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=7.0, seed=241)
    edges = lib.region_edges(labels_hi)
    max_dist = 6  # broad, soft patch boundaries, litter drifts rather than stopping sharply
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 3)
    layout = narrow + 0.8 * (narrow - wide)

    flakes = flake_noise(SIZE, seed=251) * 0.30

    # Sparse deeper gaps where the scarp shows through the litter, real
    # occluding recesses rather than a general roughening.
    gap_field = lib.blur(lib.white_noise(SIZE, seed=253), 2)
    gap_cut = float(np.percentile(gap_field, 30))
    gaps = np.where(gap_field < gap_cut, gap_field - gap_cut, 0.0) * 6.0

    height = lib.normalise01(layout + flakes + gaps, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=24, octaves=3, seed=254, gain=0.55)
    smooth = 0.35 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 11.0
    height = lib.band(height, 0.45)
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
