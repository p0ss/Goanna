"""Hand authored LabPBR height and smoothness for kythen_siku_soapstone.

The 32 px art (cultures/siku/materials.json: "mottle", base soapstone_grey,
accent soapstone_warm, cells 7) is a mottled slab, read the same way
kythen_stone.py reads default_stone's own fleck pattern: lib.segments at
0.02 finds 206 small flecks, none dominant, pits and grain in one
continuous face rather than separate stones.

"Cut soft out of the seam and hardening in the air": soapstone is famous
for taking a smooth, almost soapy polish, and the recipe's own
surface.smooth is 0.5, well past stone's packed ceiling (0.12 + 0.25 =
0.37). keep_mean=False carries that number through, the same lever
kythen_habesha_cast_bronze.py uses for its own metal, applied here to a
stone that is deliberately smoother than the class default.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_soapstone"
CLS = "stone"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    tolerance = 0.02
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:10])

    baseline = 0.5
    lo, hi = region_lum.min(), region_lum.max()
    pit = region_lum < (lo + 0.35 * (hi - lo))
    grain_mask = region_lum > (lo + 0.65 * (hi - lo))
    target = np.where(pit, 0.40, np.where(grain_mask, 0.60, baseline))  # a shallower fleck
    # than kythen_stone.py's own: soapstone is soft and worked, not pitted rock.

    labels_hi = lib.warp_labels(labels, size=SIZE, seed=161)
    edges = lib.region_edges(labels_hi)
    max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    grain = lib.fbm(SIZE, base_cells=44, octaves=3, seed=162, gain=0.55) * 0.025
    pores = lib.blur(lib.white_noise(SIZE, seed=163), 1) * 0.03
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    height = lib.band(height, 0.14)  # soapstone is worked smooth, held shallower than a
    # pitted rock face; kythen_stone.py leaves this at full depth, this one does not.
    print(f"height sd {height.std():.4f}")

    # Smoothness: kept high and even (the recipe's own 0.5), with real
    # spread from a fine, soft variation rather than following the height
    # the way a rough stone's dust-collecting pits would.
    variation = lib.fbm(SIZE, base_cells=26, octaves=3, seed=164, gain=0.55)
    smooth = 0.55 + 0.35 * variation

    albedo = lib.upscale(src[..., :3])
    normal_strength = 14.0
    keep_mean = False
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, keep_mean=keep_mean, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}, keep_mean={keep_mean}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    # tilt and ao are expected to miss: soapstone is cut soft and worked
    # smooth on purpose (the recipe's own note), a polished face rather
    # than a pitted rock, the case the brief allows to miss the stone
    # tilt band and say why.
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
