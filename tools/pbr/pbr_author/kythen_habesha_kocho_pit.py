"""Hand authored height and smoothness for kythen_habesha_kocho_pit.

The 32 px art mixes a mossy green (rgb about [0.36, 0.42, 0.24], the
commonest single shade at 45 percent of texels) with several brown, earthy
shades. Read as kocho, the fermented ensete pulp Habesha households store
in a lined pit, this is the pit's own lining: false banana leaves, still
green in patches and browned and rotting in others, packed against the
earth wall. lib.segments (tolerance 0.05) finds 153 regions, a broad green
patch and a scatter of smaller brown ones, and the art also carries faint
short vertical marks in places, read here as the leaf ribs and stem fibres
showing through the packed lining. lib.class_of reads "soil": a trodden,
packed lining behaves like packed earth, not a living plant.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_kocho_pit"
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
    print(f"segments: n={n} tolerance={tolerance}, sizes top10 {sorted(sizes.tolist(), reverse=True)[:10]}")

    baseline = 0.10
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.50 + 0.40 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=5.0, seed=171)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    clumps = lib.fbm(SIZE, base_cells=13, octaves=3, seed=172, gain=0.55) * 0.25

    # The leaf ribs and packed stem fibres the art hints at: short, mostly
    # upright strands rather than an isotropic clump.
    fibre = blur_axis(lib.fbm(SIZE, base_cells=26, octaves=2, seed=173), radius=4, axis=0) * 0.16

    grit = lib.blur(lib.white_noise(SIZE, seed=174), 1) * 0.06
    pits = lib.blur(lib.white_noise(SIZE, seed=175), 2) * 0.05
    height = lib.normalise01(layout + clumps + fibre + grit + pits, 0.5, 99.5)
    height = lib.band(height, 0.30)

    # One real deep pocket where the lining has pulled away from the pit
    # wall.
    hole_field = lib.blur(lib.white_noise(SIZE, seed=176), 1)
    hole_cut = float(np.percentile(hole_field, 0.3))
    holes = np.where(hole_field < hole_cut, (hole_field - hole_cut) * 3.2, 0.0)
    height = np.clip(height + holes, 0.0, 1.0)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=177, gain=0.55)
    smooth = 0.45 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 8.5
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
