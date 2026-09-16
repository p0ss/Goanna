"""Hand authored height and smoothness for kythen_habesha_field_stubble.

The 32 px art has a soil matrix (lib.segments, tolerance 0.05, luminance
about 0.46, the largest single region at 279 texels) and a scatter of
brighter patches, luminance about 0.58, 33 regions totalling 371 texels,
more than a third of the tile. That is too much area and too clumped to be
individual cut stalks at this resolution; it reads as standing tufts of
stubble left after harvest, pale and dry against the darker turned soil
between them, so the relief here domes those bright tufts up out of the
soil the way default_dirt.py domes a clod, rather than drawing individual
blade stamps the way mcl_core_grass_block_top.py does for a living lawn.
lib.class_of reads "soil".
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_field_stubble"
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

    baseline = 0.10
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.35 + 0.55 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=5.0, seed=131)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # Loose crumb between the tufts, a scale above the segmented dither.
    lumps = lib.fbm(SIZE, base_cells=12, octaves=3, seed=132, gain=0.55) * 0.25

    grit = lib.blur(lib.white_noise(SIZE, seed=133), 1) * 0.06
    pits = lib.blur(lib.white_noise(SIZE, seed=134), 2) * 0.05
    height = lib.normalise01(layout + lumps + grit + pits, 0.5, 99.5)
    height = lib.band(height, 0.30)

    # One real deep furrow, the odd gap the harvest left down to bare soil,
    # cut after the band rather than mixed in before it: lib.band scales by
    # its single most extreme point, and an outlier mixed in earlier would
    # flatten the ordinary tuft and crumb relief in the process.
    hole_field = lib.blur(lib.white_noise(SIZE, seed=135), 1)
    hole_cut = float(np.percentile(hole_field, 0.3))
    holes = np.where(hole_field < hole_cut, (hole_field - hole_cut) * 3.2, 0.0)
    height = np.clip(height + holes, 0.0, 1.0)
    print(f"height sd {height.std():.4f}")

    # Smoothness follows height: the soil between tufts holds dust and
    # stays rough, the dry standing stubble catches a little more sheen.
    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=136, gain=0.55)
    smooth = 0.45 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 9.0
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
