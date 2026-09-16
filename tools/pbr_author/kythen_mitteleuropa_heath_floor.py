"""Hand authored height and smoothness for kythen_mitteleuropa_heath_floor.

The 32 px art segments into 104 real regions at tolerance 0.05 (231, 202,
79 and 55 texel patches down to many small ones), and those regions split
cleanly by hue: 47 percent sit above hue 0.17 (green, mean lum 0.595,
heather sprigs) and the rest below it (tan, mean lum 0.556, bare soil and
pale lichen crust). That is low heather and lichen read straight off the
art, so each region gets its own target height by which side of that hue
split it falls on rather than by brightness alone: heather sprigs stand
proud in the upper half of the range, lichen and soil stay in the lower,
flatter half. The crown fade between regions was too gradual a wall for
the ambient occlusion, the same trap forest_loam.py hit, so a second
sparse, sharp walled layer of small gaps between the clumps carries the
real depth.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_heath_floor"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def hue_of(rgb):
    """Vectorised hue in 0..1, avoiding a python loop over 1024 texels."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx = rgb.max(axis=-1)
    mn = rgb.min(axis=-1)
    d = np.clip(mx - mn, 1e-6, None)
    h = np.zeros_like(mx)
    is_r = mx == r
    is_g = (mx == g) & ~is_r
    is_b = (mx == b) & ~is_r & ~is_g
    h = np.where(is_r, ((g - b) / d) % 6.0, h)
    h = np.where(is_g, (b - r) / d + 2.0, h)
    h = np.where(is_b, (r - g) / d + 4.0, h)
    return (h / 6.0) % 1.0


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    hue = hue_of(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print(f"hue min {hue.min():.3f} max {hue.max():.3f}")
    print("class:", CLS)

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    print(f"segments: n={n} sizes_top={sorted(sizes.tolist(), reverse=True)[:6]}")

    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    region_hue = np.array([hue[labels == i].mean() for i in range(n)])
    is_green = region_hue > 0.17
    print(f"green (heather) regions: {int(is_green.sum())} of {n}, "
          f"green mean lum {region_lum[is_green].mean():.3f}, "
          f"tan mean lum {region_lum[~is_green].mean():.3f}")

    lo, hi = region_lum.min(), region_lum.max()
    brightness = (region_lum - lo) / max(hi - lo, 1e-6)
    # Heather stands proud in the top half of the range, lichen and soil
    # stay flatter in the bottom half.
    target = np.where(is_green, 0.55 + 0.35 * brightness, 0.20 + 0.30 * brightness)

    labels_hi = lib.warp_labels(labels, amp=5.0, seed=911)
    edges = lib.region_edges(labels_hi)
    max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    crown = narrow + 1.1 * (narrow - wide)

    lumps = lib.fbm(SIZE, base_cells=10, octaves=3, seed=912, gain=0.55) * 0.15
    grit = lib.blur(lib.white_noise(SIZE, seed=913), 1) * 0.05
    crown_field = lib.normalise01(crown + lumps + grit, 0.5, 99.5)
    crown_band_hw = 0.28
    crown_field = lib.band(crown_field, crown_band_hw)

    # Small sharp walled gaps between the clumps, bare ground showing
    # through, the real depth the crown fade alone could not give the ao.
    rng = np.random.default_rng(914)
    gap_native = (rng.uniform(0.0, 1.0, (src.shape[0], src.shape[0])) < 0.09).astype(int)
    gaps = lib.warp_labels(gap_native, amp=1.5, seed=914).astype(np.float32)
    print(f"gap fraction {gaps.mean():.3f}")

    gap_depth = 0.35
    height = np.clip(crown_field - gaps * gap_depth, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=915, gain=0.55)
    green_hi = is_green[labels_hi].astype(np.float32)
    # Heather's own leaf wax reads a touch less matte than the lichen
    # crust; gaps down to bare ground hold dust and stay rough.
    smooth = 0.45 * t + 0.55 * variation - 0.10 * gaps - 0.08 * green_hi
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 12.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength} crown_band_hw={crown_band_hw} gap_depth={gap_depth}")
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
