"""Hand authored height and smoothness for kythen_khmer_carved_sandstone.

The 32 px art is a flat dressed face with a motif engraved into it, the
same situation mcl_core_sandstone_carved.py describes for Mineclonia's own
creeper faced sandstone. lib.segments at tolerance 0.06 finds 85 regions:
one huge flat field (893 of 1024 texels) and a long tail of one, two and
three texel shapes, the engraving read as regions the way
mcl_core_sandstone_carved.py's own segmentation reads its design.

lib.class_of reads "sand" back from the bake, kept here: this is the same
material as kythen_khmer_sandstone_good.py's dressed blocks, just with a
motif cut into the face, so the relief stays at sand's own shallow tilt
band. The carve is a small warp free bevel over the flat baseline, amp 0
on the label warp because a mason's engraving is dressed, manufactured
work, not a natural surface.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_carved_sandstone"
CLS = "sand"
SIZE = lib.SIZE

GRAIN_SEED = 781
PORES_SEED = 782


def main(out_dir):
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"class_of reads: {lib.class_of(STEM, GAME)} (kept)")

    tolerance = 0.06
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = [int((labels == i).sum()) for i in range(n)]
    print(f"segments: n={n} tolerance={tolerance} sizes {sorted(sizes, reverse=True)[:10]} ...")

    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    lo, hi = lum.min(), lum.max()
    region_target = 0.2 + 0.65 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=0.0, seed=791, cells=14)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    flat = 0.5
    # A shallow carve: the motif only reaches a third of the way from the
    # flat face to its own region target, a sand class relief.
    target_map = region_target[labels_hi]
    layout = flat + (target_map - flat) * t * 0.35

    grain = lib.fbm(SIZE, base_cells=44, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=PORES_SEED), 1) * 0.05
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=24, octaves=3, seed=793, gain=0.55)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 4.5
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
    lines = main(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
