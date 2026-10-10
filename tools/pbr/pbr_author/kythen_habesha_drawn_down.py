"""Hand authored height and smoothness for kythen_habesha_drawn_down.

The 32 px art is very dark, luminance 0.08 to 0.213, and almost
monochrome: one near neutral shade covers 49 percent of the texels in one
657 texel connected region (lib.segments, tolerance 0.05, n=19), a warmer
brown shade forms two smaller patches of 123 and 90 texels, and a scatter
of near black texels sits below both. Read as ground, this is a trodden
path: a dark, compacted crust worn smooth over most of the tile, broken by
patches where the crust has scuffed through to the warmer soil beneath, and
a few near black flecks of ash or char trodden in. "Drawn down" reads as
the crust dragged and scuffed rather than dug, so a faint directional drag
streak sits on top of the patch structure, the mark of feet or a hoe pulled
one way across it.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_drawn_down"
CLS = lib.class_of(STEM, GAME)
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
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"lib.class_of reads: {CLS}")

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}, sizes {sorted(sizes.tolist(), reverse=True)}")

    # The crust (the big dark region) is worn low and smooth; the warmer
    # scuffed through patches sit a touch higher, disturbed soil rather
    # than compacted crust.
    baseline = 0.30
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.30 + 0.55 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=6.0, seed=111)
    edges = lib.region_edges(labels_hi)
    max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # A faint drag mark, one consistent direction, from whatever was pulled
    # across the ground to draw it down.
    drag = blur_axis(lib.fbm(SIZE, base_cells=10, octaves=2, seed=112), radius=6, axis=0) * 0.14

    clumps = lib.fbm(SIZE, base_cells=12, octaves=3, seed=113, gain=0.55) * 0.20
    grit = lib.blur(lib.white_noise(SIZE, seed=114), 1) * 0.05
    pits = lib.blur(lib.white_noise(SIZE, seed=115), 2) * 0.05
    hole_field = lib.blur(lib.white_noise(SIZE, seed=116), 1)
    hole_cut = float(np.percentile(hole_field, 0.3))
    holes = np.where(hole_field < hole_cut, (hole_field - hole_cut) * 10.0, 0.0)

    height = lib.normalise01(layout + drag + clumps + grit + pits + holes, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    # The compacted crust is smoother; the scuffed, disturbed patches hold
    # more dust and stay rougher.
    variation = lib.fbm(SIZE, base_cells=16, octaves=3, seed=117, gain=0.55)
    smooth = 0.5 * (1.0 - t) + 0.5 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 18.0
    height = lib.band(height, 0.32)
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
