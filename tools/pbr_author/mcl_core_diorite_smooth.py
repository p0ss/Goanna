"""Hand authored LabPBR height and smoothness for mcl_core_diorite_smooth.

The 16 px art is a single polished slab, the same construction as
mcl_core_granite_smooth: eight shades from 0.430 to 0.746, lib.segments
finds only faint crystal flecks in one connected body. The edge again
carries the bevel: row 0 (mean 0.687) and columns 0 and 1 (means 0.683,
0.683) sit above the overall mean (0.607), row 15 (0.508) and columns 14
and 15 (0.524, 0.518) sit below it, every other row and column staying
within 0.58 to 0.64. A light lip top and left, a shadowed rebate bottom
and right, the same shallow bevel granite draws.

An earlier version of this script put full strength crystal noise and a
pore layer into the height field on top of the bevel. The bake gives the
stone class the parallax depth of a mortar joint, so on a face that should
be nearly flat, that turned every pore into a visible pit and the bevel
read as a frame around a pitted surface rather than the edge of a polished
slab. A polished crystalline face varies in gloss between the crystal
grains and the matrix around them, not in height, so the crystal texture
now lives in the smoothness field and the height keeps only a few percent
of the range for crystal and pore relief, the bevel carrying almost all of
the real shape.
"""
import sys

import numpy as np

import lib

STEM = "mcl_core_diorite_smooth"
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
    # so it wins the corner where the two bands would otherwise overlap.
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

    labels_hi = lib.warp_labels(label, amp=2.5, cells=10, seed=71)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # shallow, a texel or two either side of the rebate line
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target.items():
        target_map[labels_hi == lbl] = val
    layout = baseline + (target_map - baseline) * t

    # The crystal pattern and the polish pores: kept here at a small
    # fraction of the height range (aiming for a few percent, see the
    # measurement printed below) so the body reads as flat stone with the
    # bevel carrying almost all of the real shape. Denser grain than the
    # old, unclipped version (130 cells rather than 44): a face this flat
    # still needs to tile without a visible step at the wrap join, and
    # finer grain gives the interior of the tile its own small texel to
    # texel variation to measure that step against, without needing a
    # bigger height amplitude to get there.
    crystal = lib.fbm(lib.SIZE, base_cells=130, octaves=3, seed=72, gain=0.55)
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=73), 1)
    height = lib.normalise01(layout + crystal * 0.014 + pores * 0.009, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")
    body = height[labels_hi == 0]
    print(f"body (flat region only) height sd {body.std():.4f}, "
          f"range {body.max() - body.min():.4f} of the full 0..1 height")

    # Smoothness follows the same regions as height, not height's own
    # value, so it stays periodic without any fold: the polished flat body
    # and its lit lip are both the dressed face and stay smooth, the
    # rebate at the shadowed edge catches dust and stays rougher. The
    # crystal pattern lives here now rather than in height: a polished
    # crystalline face varies in gloss between crystal and matrix without
    # varying in height, so the same crystal field drives gloss instead.
    smooth_target = {0: 0.65, 1: 0.65, 2: 0.35}
    smooth_target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in smooth_target.items():
        smooth_target_map[labels_hi == lbl] = val
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=74)
    smooth = 0.5 + (smooth_target_map - 0.5) * t + 0.22 * crystal + 0.10 * rough_noise
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
    # The tilt target of 28 to 40 degrees was written for rough stone, a
    # cobble or a gravel with real structure across the whole face. A
    # polished slab that is flat bar its bevel cannot reach that without
    # putting the crystal and pore speckle back into height, which is the
    # defect this rework removes, so the tilt above is reported, not
    # chased.
    print("note tilt target is for rough stone; a polished slab flat bar "
          "its bevel will not reach it without speckle, so it is reported "
          "above, not chased")
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
