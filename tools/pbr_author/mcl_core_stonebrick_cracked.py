"""Hand authored height and smoothness for mcl_core_stonebrick_cracked.

The 16 px art is default_stone_brick's own masonry with a crack drawn over
it: the same two course, running bond layout (a wide upper flagstone, a
lower course split in two by one full height joint) shows up at the same
rows and column once the shading is thresholded the way
default_stone_brick.py finds its mortar. lum <= 0.38 recovers exactly rows
7 and 15 as full width joints and column 7 for rows 8 to 14 as the lower
course's own split, the same geometry default_stone_brick.py's docstring
describes, so this block reuses that mask directly (as fixed cells, not a
per texel threshold, so the crack drawn on top of it cannot perturb the
joint layout) and default_stone_brick.py's own label_blocks, crown, tooling
and pore seeds, so it sits beside plain stone brick as the same masonry.

What is left over after the structural joint is subtracted, at that same
0.38 cut, is 29 texels that do not belong to any row 7, row 15 or column 7
joint: a jagged line from the upper right corner across the top course and
down the lower course's right edge. That is the crack, and it becomes its
own narrow, deep groove on top of the shared masonry relief, not a second
set of mortar.
"""

import sys

import numpy as np

import lib
import default_stone_brick as dsb

STEM = "mcl_core_stonebrick_cracked"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    # The structural joint, fixed at the geometry default_stone_brick.py
    # found for its own art: two courses, the lower one split at column 7.
    # Fixed cells rather than a threshold on this texture's own shading, so
    # the crack (which is drawn darker than the joint in places) cannot
    # eat into the block partition.
    mortar_mask = np.zeros((16, 16), dtype=bool)
    mortar_mask[7, :] = True
    mortar_mask[15, :] = True
    mortar_mask[8:15, 7] = True
    print(f"structural joint texels: {int(mortar_mask.sum())} of 256")

    labels, n_blocks = dsb.label_blocks(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_blocks)]
    print(f"blocks found: {n_blocks}, sizes {sizes}")

    block_lum = np.array([lum[labels == i].mean() for i in range(n_blocks)])
    lo, hi = lum[~mortar_mask].min(), lum[~mortar_mask].max()
    block_target = 0.55 + 0.35 * (block_lum - lo) / max(hi - lo, 1e-6)
    target_dict = {-1: 0.08}
    for i in range(n_blocks):
        target_dict[i] = float(block_target[i])

    mortar_hi = np.repeat(np.repeat(mortar_mask, 16, axis=0), 16, axis=1)
    labels_hi = np.repeat(np.repeat(labels, 16, axis=0), 16, axis=1)

    max_dist = 5  # same groove half width as default_stone_brick.py
    dist = lib.distance_to_edge(mortar_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(lib.SIZE, base_cells=36, octaves=2, seed=26) * 1.3
    dist = np.where(mortar_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target_dict.items():
        target_map[labels_hi == lbl] = val
    layout = target_map * t

    crown = lib.fbm(lib.SIZE, base_cells=4, octaves=2, seed=22) * 0.05
    layout = layout + crown * t

    tooling = lib.fbm(lib.SIZE, base_cells=48, octaves=3, seed=23, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=24), 1) * 0.05

    # The crack: whatever is darker than 0.38 and is not part of the
    # structural joint above. A jagged line, not a region, so it is turned
    # into a groove with distance_to_edge the same way a joint is, but
    # narrower and cut deeper, since a crack is a fracture, not a course
    # line the mason left on purpose.
    crack_thresh = 0.38
    crack_mask = (lum <= crack_thresh) & ~mortar_mask
    print(f"crack texels: {int(crack_mask.sum())} of 256 at threshold {crack_thresh}")
    crack_hi = np.repeat(np.repeat(crack_mask, 16, axis=0), 16, axis=1)
    crack_max_dist = 3
    crack_dist = lib.distance_to_edge(crack_hi.astype(np.float32), max_dist=crack_max_dist)
    crack_wobble = lib.fbm(lib.SIZE, base_cells=40, octaves=2, seed=91) * 0.7
    crack_dist = np.clip(crack_dist + crack_wobble, 0.0, crack_max_dist)
    crack_t = np.clip(crack_dist / crack_max_dist, 0.0, 1.0)
    crack_depth = (1.0 - crack_t * crack_t) * 0.28  # narrow, deep groove

    height = lib.normalise01(layout + tooling + pores - crack_depth, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height, plus the crack itself stays rough: a
    # fracture does not polish the way a dressed face does.
    rough_noise = lib.fbm(lib.SIZE, base_cells=18, octaves=3, seed=25)
    smooth = 0.55 * height + 0.5 * rough_noise - 0.25 * (1.0 - crack_t)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 40  # same masonry depth as default_stone_brick.py
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
