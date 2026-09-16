"""Hand authored height and smoothness for kythen_habesha_afroalpine_mat.

The 32 px art is a dithered olive and khaki mat, four grey shades, no drawn
outline: lib.segments (tolerance 0.05) still finds 111 real regions, most a
handful of texels, a few dozen texels across. This is a carpet of afroalpine
cushion plants seen from above: low, rounded mounds a hand's width across
in the real world, packed edge to edge with no soil showing between them.
The lighter dithered patches are mound tops catching the light, the darker
patches are the shaded gaps between mounds, and the many small regions the
segmenter finds are exactly those mounds and gaps. lib.class_of reads
"soil": this is a dense, matte, low profile mat rather than the upright
blade structure of a grass top, closer in behaviour to a lumpy ground cover
than to leaves.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_afroalpine_mat"
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

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}, sizes top10 {sorted(sizes.tolist(), reverse=True)[:10]}")

    # Target height per region straight off its own brightness: a lit mound
    # top rises, a shaded gap between mounds sinks. The floor sits well
    # below the mound tops, the way a real cushion mat shows real dark
    # crevices between the mounds, not just a gentle dip.
    baseline = 0.05
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.60 + 0.35 * (region_lum - lo) / max(hi - lo, 1e-6)

    # Natural, irregular ground cover: warp the region boundaries so a mound
    # has a rounded silhouette rather than the dither's own square edges.
    labels_hi = lib.warp_labels(labels, amp=5.0, seed=51)
    edges = lib.region_edges(labels_hi)
    max_dist = 2  # a tight taper: a real narrow crevice between mounds,
                  # not a broad shallow dip ao_from_height cannot see
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # Cushion mounds clump at a scale above the segmented dither, rounder
    # than a clod and with no preferred direction.
    mounds = lib.fbm(SIZE, base_cells=14, octaves=3, seed=52, gain=0.55) * 0.35

    # Below the texel: the felted surface of the cushion plants themselves,
    # plus the odd real gap down to bare ground where a mound has died back
    # or never closed, deep and narrow rather than a broad shallow dip.
    grit = lib.blur(lib.white_noise(SIZE, seed=53), 1) * 0.06
    pits = lib.blur(lib.white_noise(SIZE, seed=54), 2) * 0.05
    hole_field = lib.blur(lib.white_noise(SIZE, seed=56), 1)
    hole_cut = float(np.percentile(hole_field, 0.2))
    holes = np.where(hole_field < hole_cut, (hole_field - hole_cut) * 14.0, 0.0)

    height = lib.normalise01(layout + mounds + grit + pits + holes, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    # Smoothness follows the mound shape: gaps hold shade and stay rough, a
    # mound top wears a touch smoother, plus the mat's own patchy variation.
    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=55, gain=0.55)
    smooth = 0.45 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 9.0
    # A dense mat, not a cobble: held in a band scaled to a mound's real
    # relief rather than stretched to the full class depth.
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
