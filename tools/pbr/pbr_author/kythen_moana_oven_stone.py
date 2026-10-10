"""Hand authored height and smoothness for kythen_moana_oven_stone.

The 32 px art has five shades, sd 0.095, with a clean gap between the
darkest two (0.292, 0.353, 33.5 percent of the tile combined) and the
lightest three (0.516, 0.59, 0.622, 66.5 percent), the same shape of split
kythen_habesha_river_gravel.py finds in its own pebble art. The dark group
reads as the cracks and soot between rounded fire cracked stones, the light
group as the stones themselves, brightness setting each stone's own height.
Built the gravel way, a gap group and a dome group domed per region, but
with a wider taper and a low frequency crown so the stones read as rounded
lumps, several source texels across, rather than gravel's own small tight
pebbles.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_oven_stone"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"lib.class_of reads: {CLS}")

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])

    baseline = 0.10
    gap = region_lum <= 0.42
    dome = ~gap
    print(f"gap (crack/soot) regions: {int(gap.sum())} of {n}, {int(sizes[gap].sum())} texels; "
          f"dome (stone) regions: {int(dome.sum())}, {int(sizes[dome].sum())} texels")
    dlo, dhi = region_lum[dome].min(), region_lum[dome].max()
    target = np.where(gap, baseline,
            0.55 + 0.35 * (region_lum - dlo) / max(dhi - dlo, 1e-6))

    labels_hi = lib.warp_labels(labels, amp=6.0, seed=921)
    edges = lib.region_edges(labels_hi)
    max_dist = 5  # rounded stones several source texels across, a wider taper than gravel's own
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # A low frequency crown so the bigger stones round off once the edge
    # taper saturates flat in the middle.
    crown = lib.fbm(SIZE, base_cells=7, octaves=2, seed=922) * 0.10
    layout = layout + crown * t

    # Fire cracking: a fine crazed texture across the stone faces, plus
    # ordinary pores.
    cracking = lib.fbm(SIZE, base_cells=46, octaves=3, seed=923, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(SIZE, seed=924), 1) * 0.05
    height = lib.normalise01(layout + cracking + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=925)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 16
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
