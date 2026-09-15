"""Hand authored height and smoothness for mcl_core_sandstone_carved.

The cut face mcl_core_sandstone_top.py and mcl_core_sandstone_normal.py
describe, with a pattern engraved into it: the classic creeper faced
sandstone. lib.segments at tolerance 0.06 finds 22 regions, one large flat
field (178 of 256 texels) and a long tail of small shapes, which is the
engraving read as regions the way mcl_core_stonebrick_carved.py's own
segmentation reads its design.

This is still a sand class face (mcl_core_sandstone_normal.py's own tilt
target is 8 to 16 degrees, far shallower than a stone brick's 28 to 40), so
the relief stays shallow: a small warp, a narrow bevel and a modest
amplitude, sitting on the same flat baseline and sharing the same fine
grain and pore noise (seeds 61, 62) as mcl_core_sandstone_normal.py, so the
carved face reads as the same stone as the other three.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_sandstone_carved"
CLS = "sand"
SIZE = lib.SIZE

GRAIN_SEED = 61
PORES_SEED = 62


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")

    tolerance = 0.06
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = [int((labels == i).sum()) for i in range(n)]
    print(f"segments: n={n} tolerance={tolerance} sizes {sorted(sizes, reverse=True)}")

    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    lo, hi = lum.min(), lum.max()
    region_target = 0.2 + 0.65 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=0.0, seed=41, cells=14)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    flat = 0.5
    # A shallow carve: the pattern only reaches a third of the way from the
    # flat face to the full region target, a sand class relief rather than
    # a stone one.
    target_map = region_target[labels_hi]
    layout = flat + (target_map - flat) * t * 0.35

    grain = lib.fbm(SIZE, base_cells=44, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=PORES_SEED), 1) * 0.05
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=24, octaves=3, seed=73, gain=0.55)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 4.5
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
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
