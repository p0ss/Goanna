"""Hand authored LabPBR height and smoothness for kythen_mitteleuropa_stone.

The 32 px art is a mottled grey, four shades from 0.346 to 0.474, mean
0.403, no drawn joint or cobble outline anywhere in the tile: one
continuous natural rock face, the same reading kythen_stone.py and
default_stone.py give their own mottled art. The flecks are the rock's own
pitting and grain, not separate stones, so the relief is soft dishes and
mounds over one slab rather than domed, mortared pieces.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_stone"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print(f"lib.class_of reads: {CLS}")

    tolerance = 0.02
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15], "...")

    # Only the flecks clearly darker or lighter than the matrix are cut
    # down or raised; everything in between stays the untouched matrix, the
    # same rule kythen_stone.py and default_stone.py use so the depth is
    # not spread thin over every one of the many small flecks.
    baseline = 0.5
    lo, hi = region_lum.min(), region_lum.max()
    pit = region_lum < (lo + 0.35 * (hi - lo))
    grain_mask = region_lum > (lo + 0.65 * (hi - lo))
    print(f"pit flecks: {int(pit.sum())}, grain flecks: {int(grain_mask.sum())}, "
          f"matrix flecks: {int(n - pit.sum() - grain_mask.sum())}")
    target = np.where(pit, 0.30, np.where(grain_mask, 0.70, baseline))

    labels_hi = lib.warp_labels(labels, size=SIZE)
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # soft mounds and dishes, not outlined pieces
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    grain = lib.fbm(SIZE, base_cells=40, octaves=3, seed=851, gain=0.55) * 0.04
    pores = lib.blur(lib.white_noise(SIZE, seed=852), 1) * 0.05
    # A scatter of a few genuinely deep pits, sparse enough (0.3 percent of
    # the map) that a soft dished slab still reads as one continuous rock
    # face rather than cobbled pieces, but real enough to self shadow:
    # without them this slab has no recess deep enough to occlude at all,
    # the same shortfall kythen_stone.py's own soft-dish build shows (ao
    # min 0.87 there, checked by hand). Kept out of lib.band, unlike a
    # manufactured face's faint texture: this is the class's own depth, a
    # rock face with real pockets, so normalise01 spreads it to the byte
    # and normal_strength alone is tuned down to keep the tilt in band.
    pit_field = lib.blur(lib.white_noise(SIZE, seed=854), 1)
    pit_cut = float(np.percentile(pit_field, 0.3))
    deep_pit = np.where(pit_field < pit_cut, (pit_field - pit_cut) * 10.0, 0.0)
    height = lib.normalise01(layout + grain + pores + deep_pit, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=853)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 22
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
