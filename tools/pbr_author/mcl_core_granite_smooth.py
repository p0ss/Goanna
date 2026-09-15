"""Hand authored LabPBR height and smoothness for mcl_core_granite_smooth.

The 16 px art is a single polished slab: 19 shades within a narrow 0.369 to
0.606 band, no colour cliff anywhere, lib.segments finds only faint
crystal flecks in a body that stays one connected region until tolerance
drops so low the flecks themselves fragment. What does line up cleanly is
the tile's own edge: row 0 (mean 0.581) and columns 0 and 1 (means 0.563,
0.562) sit well above the row and column average, row 15 (0.413) and
columns 14 and 15 (0.412, 0.408) sit well below it, and every row and
column in between stays within 0.474 to 0.527. That is the shallow bevel
the art draws: a light lip along the top and left edge of the cut block,
a shadowed rebate along the bottom and right, the rest of the face flat
bar its crystal grain.
"""
import sys

import numpy as np

import lib

STEM = "mcl_core_granite_smooth"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", len(set(np.round(lum.ravel(), 3).tolist())))
    print("row means:", np.round(lum.mean(axis=1), 3).tolist())
    print("col means:", np.round(lum.mean(axis=0), 3).tolist())

    labels, n = lib.segments(rgb, tolerance=0.06)
    sizes = sorted(np.bincount(labels.ravel()).tolist(), reverse=True)
    print(f"segments tolerance 0.06: n={n}, largest sizes {sizes[:6]} "
          "(one body region, the rest crystal flecks; too fine to build a bevel from)")

    # The bevel: label 1 the lit top and left edge, label 2 the shadowed
    # bottom and right edge, label 0 the flat body. The lip is written last
    # so it wins the corner where the two bands would otherwise overlap,
    # matching the art (row 15, column 0 comes back bright, not dark).
    label = np.zeros((16, 16), dtype=int)
    label[15, :] = 2
    label[:, 14] = 2
    label[:, 15] = 2
    label[0, :] = 1
    label[:, 0] = 1
    label[:, 1] = 1
    sizes16 = [int((label == i).sum()) for i in range(3)]
    print(f"bevel labels: body {sizes16[0]}, lip {sizes16[1]}, shadow {sizes16[2]}")

    # The bevel lives on the tile's edge, and its relief must sit exactly
    # where the art draws it: rolled off the edge to please the seam
    # measure it drew a cross through the middle of the block on the ramp.
    # The wrap join is a real lip to shadow step here and reads high in
    # seam_n; that is the art, not a defect.

    baseline = 0.5
    target = {0: baseline, 1: 0.62, 2: 0.2}

    labels_hi = lib.warp_labels(label, amp=2.5, cells=10, seed=61)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # shallow, a texel or two either side of the rebate line
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target.items():
        target_map[labels_hi == lbl] = val
    layout = baseline + (target_map - baseline) * t

    # Only faint crystal texture: fine, dense grain so its slope still
    # carries real tilt even though its own height amplitude is small, and
    # sparser pores from the polish missing a pit here and there.
    grain = lib.fbm(lib.SIZE, base_cells=44, octaves=3, seed=62, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=63), 1) * 0.035
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the same regions as height, not height's own
    # value, so it stays periodic without any fold: the polished flat body
    # and its lit lip are both the dressed face and stay smooth, the
    # rebate at the shadowed edge catches dust and stays rougher.
    smooth_target = {0: 0.65, 1: 0.65, 2: 0.35}
    smooth_target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in smooth_target.items():
        smooth_target_map[labels_hi == lbl] = val
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=64)
    smooth = 0.5 + (smooth_target_map - 0.5) * t + 0.3 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 34
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
