"""Hand authored LabPBR height and smoothness for crafting_workbench_top.

Segmenting the art at tolerance 0.08 gives twelve regions: a big background
region (156 texels, mean lum 0.545, the plain plank and its outer frame), a
second region of 63 texels at 0.358 that traces a bordered box from row 3
to row 12 with two more dividers crossing it, and nine 2 by 2 texel regions
sitting inside that box in a neat 3 by 3 arrangement (each its own mean lum,
0.488 to 0.537), cols 4 to 5, 7 to 8, 10 to 11 by rows 4 to 5, 7 to 8, 10 to
11. That is a drawn 3 by 3 crafting grid: the 63 texel region is its border
and dividers, one texel wide, and the nine cells are its squares. The grid
sits inside the outer plank, which is otherwise plain.
"""
import sys

import numpy as np

import lib

STEM = "crafting_workbench_top"
CLS = "wood"
SIZE = lib.SIZE
SEG_TOLERANCE = 0.08


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    labels, n = lib.segments(rgb, tolerance=SEG_TOLERANCE)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={SEG_TOLERANCE}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    kerf_label = int(np.argmax(sizes * (sizes < 100)))  # the 63 texel border and dividers
    cell_labels = [i for i in range(n) if i != kerf_label and sizes[i] < 10]
    print(f"kerf region: {kerf_label}, size {sizes[kerf_label]}, {len(cell_labels)} grid cells found")

    # Straight from the mask at 16x its own resolution: a saw kerf is a
    # machined line, not something a warp should round off, the way
    # default_stone_brick keeps its dressed joints exact.
    kerf_mask = labels == kerf_label
    kerf_hi = np.repeat(np.repeat(kerf_mask, 16, axis=0), 16, axis=1).astype(np.float32)
    max_dist = 3  # a shallow scribed line, not a masonry joint
    dist = lib.distance_to_edge(kerf_hi, max_dist=max_dist)
    dist = np.where(kerf_hi > 0.5, 0.0, dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: flat plank either side, sharp fall into the kerf

    # Each grid cell rides a touch above the plank at its own mean
    # brightness, echoing the region means the segmentation found rather
    # than one flat level for all nine.
    cell_hi = np.zeros((SIZE, SIZE), dtype=np.float32)
    for i in cell_labels:
        mask_hi = np.repeat(np.repeat(labels == i, 16, axis=0), 16, axis=1)
        lift = 0.03 + 0.05 * (region_lum[i] - region_lum[cell_labels].min()) / max(
                region_lum[cell_labels].max() - region_lum[cell_labels].min(), 1e-6)
        cell_hi[mask_hi] = lift

    plank_level = 0.55
    kerf_level = 0.30
    layout = plank_level * t + kerf_level * (1 - t) + cell_hi * t

    # Board seams under the frame, so the top reads as the same timber as
    # the front and side rather than a bare panel: same grain seed family.
    grain = lib.fbm(SIZE, base_cells=20, octaves=3, seed=51, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=52), 1) * 0.03

    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: the plank is smoother, the kerf and its dust rougher, the
    # cells inherit the plank's own patchy variation.
    rough_noise = lib.fbm(SIZE, base_cells=18, octaves=3, seed=53)
    smooth = 0.5 * t + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 17.0
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
