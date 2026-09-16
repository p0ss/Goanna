"""Hand authored height and smoothness for kythen_mitteleuropa_heath_podzol.

The 32 px art has three shades, all pale and low saturation (hue steady
around 0.11, no green or tan split the way heath_floor's own art has),
segmenting into 58 real regions (299 and 210 texel patches down to many
smaller ones). This is a pale sandy soil, its own colour already reading
as bleached and mineral, so the region crown carries the brightness
straight and the finer detail leans more on grain than heath_floor's
heather does. As with every other region built script in this batch, the
crown fade alone left the ambient occlusion above 0.35 whatever the band
or strength, so a sparse, sharp walled scatter of small pits, the loosely
packed sand's own gaps, carries the real depth.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_heath_podzol"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("class:", CLS)

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    print(f"segments: n={n} sizes_top={sorted(sizes.tolist(), reverse=True)[:6]}")

    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.20 + 0.55 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=4.0, seed=921)
    edges = lib.region_edges(labels_hi)
    max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    crown = narrow + 1.1 * (narrow - wide)

    lumps = lib.fbm(SIZE, base_cells=14, octaves=3, seed=922, gain=0.55) * 0.15
    grain = lib.fbm(SIZE, base_cells=60, octaves=2, seed=923, gain=0.5) * 0.10
    dust = lib.blur(lib.white_noise(SIZE, seed=924), 1) * 0.06
    crown_field = lib.normalise01(crown + lumps + grain + dust, 0.5, 99.5)
    crown_band_hw = 0.26
    crown_field = lib.band(crown_field, crown_band_hw)

    rng = np.random.default_rng(925)
    pit_native = (rng.uniform(0.0, 1.0, (src.shape[0], src.shape[0])) < 0.08).astype(int)
    pits = lib.warp_labels(pit_native, amp=1.3, seed=925).astype(np.float32)
    print(f"pit fraction {pits.mean():.3f}")

    pit_depth = 0.42
    height = np.clip(crown_field - pits * pit_depth, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=926, gain=0.55)
    smooth = 0.4 * t + 0.6 * variation - 0.08 * pits
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 14.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength} crown_band_hw={crown_band_hw} pit_depth={pit_depth}")
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
