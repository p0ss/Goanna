"""Hand authored height and smoothness for kythen_khmer_laterite_ground.

The 32 px art has no coursing at all, unlike kythen_khmer_laterite.py's
block work: lib.segments at tolerance 0.06 finds one big connected field
(751 of 1024 texels, the common ground colour) and a scatter of smaller
clumps and pits down to single texels, exactly the loose, trodden texture
of ground made from broken laterite rather than the quarried block itself.
lib.class_of reads "soil" back from the bake, kept.

Unlike the dressed and coursed Khmer stems, this is a natural surface, so
lib.warp_labels runs with a real amplitude: the clumps get rounded,
irregular edges rather than the pixel grid's own square ones. Relief comes
from the region layout plus a denser pit field than the block laterite,
since trodden ground carries more loose texture than a dressed face.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_laterite_ground"
CLS = "soil"
SIZE = lib.SIZE


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
    print(f"segments: n={n} tolerance={tolerance} sizes {sorted(sizes, reverse=True)[:12]} ...")

    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    lo, hi = lum.min(), lum.max()
    region_target = 0.25 + 0.55 * (region_lum - lo) / max(hi - lo, 1e-6)

    # A real warp: this is trodden ground, a natural surface, so its clumps
    # get rounded, irregular silhouettes rather than the art's own square
    # texel edges.
    labels_hi = lib.warp_labels(labels, amp=5.0, seed=811, cells=10)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = region_target[labels_hi]
    layout = target_map * t

    # A denser pit and clump field than the block laterite: this is loose
    # broken material, not a dressed face.
    pit_field = lib.blur(lib.white_noise(SIZE, seed=812), 1)
    pit_cut = float(np.percentile(pit_field, 28))
    pits = np.where(pit_field < pit_cut, pit_field - pit_cut, 0.0)
    grain = lib.fbm(SIZE, base_cells=20, octaves=3, seed=813, gain=0.55) * 0.10

    height = lib.normalise01(layout + 0.45 * pits + grain, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=22, octaves=3, seed=814, gain=0.55)
    smooth = 0.35 * height + 0.65 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 12.0
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
