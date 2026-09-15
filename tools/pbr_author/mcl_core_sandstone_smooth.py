"""Hand authored height and smoothness for mcl_core_sandstone_smooth.

A flat cut face, the same idea mcl_core_sandstone_top.py builds: shade
standard deviation here is 0.061, against mcl_core_sandstone_carved.py's
own 0.076 and mcl_core_sandstone_top.py's tight 0.027. That sits it between
the two, and looking at the actual segmentation (lib.segments at the same
0.06 tolerance the carved face uses turns up the same large flat field plus
a much smaller tail of shapes, 14 regions here against carved's 22) this
face carries a faint echo of the same engraved motif, not a blank cut. It
is built the same way as mcl_core_sandstone_carved.py, the same segments,
the same small warp, but at a third of the amplitude and a shallower
taper, so it stays what the brief calls a flat dressed face, with the
pattern only just readable rather than carved, and shares its grain and
pore noise (seeds 61, 62) with the other three sandstone faces.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_sandstone_smooth"
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

    labels_hi = lib.warp_labels(labels, amp=0.0, seed=42, cells=14)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    flat = 0.5
    # A third of the carved face's own amplitude: the design is there, but
    # only just, the way this face's tighter shade spread reads.
    target_map = region_target[labels_hi]
    layout = flat + (target_map - flat) * t * 0.12

    grain = lib.fbm(SIZE, base_cells=44, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=PORES_SEED), 1) * 0.05
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=26, octaves=3, seed=74, gain=0.55)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 3.2
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
