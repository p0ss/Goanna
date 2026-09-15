"""Hand authored LabPBR height and smoothness for crafting_workbench_front.

crafting_workbench_front.png and crafting_workbench_side.png are the same
file byte for byte (md5 515f613f81e6cf2c548ee3051ee30c50 both), so this
script and crafting_workbench_side.py build the same relief from the same
art; the game already draws the same picture on both faces.

The art is a plank panel with a narrow lighter trim across the very top two
rows (row means 0.618 and 0.570, against 0.29 to 0.48 for the rest) and, in
the fourteen rows below that, a busy carved motif of crossed tool shapes.
Segmenting the panel at tolerance 0.1 gives one big background region (153
texels, mean lum 0.335, the plain plank) and two elongated regions sitting
across the vertical middle (28 texels at 0.466 and 16 texels at 0.43,
together tracing an hourglass that widens at rows 5 to 6 and narrows above
and below it, the crossed saw and square of the classic workbench front)
plus a scatter of small, much darker regions (down to 0.253) threaded
through that shape, its engraved linework. The trim rows are their own
region at tolerance 0.1 as well, exactly rows 0 and 1, 32 texels.
"""
import sys

import numpy as np

import lib

STEM = "crafting_workbench_front"
CLS = "wood"
SIZE = lib.SIZE
SEG_TOLERANCE = 0.1
TOOL_LUM_MIN = 0.40
LINE_LUM_MAX = 0.30


def build(stem):
    src = lib.load_source(stem)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{stem}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    labels, n = lib.segments(rgb, tolerance=SEG_TOLERANCE)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={SEG_TOLERANCE}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:10])

    # The trim is exactly rows 0 and 1, found by row position rather than by
    # region id: it is a straight machined edge (the top lip of the panel
    # frame), not something a warp should soften.
    trim_row = np.zeros((16, 16), dtype=bool)
    trim_row[0:2, :] = True
    print(f"trim rows: {int(trim_row.sum())} texels")

    interior = ~trim_row
    tool_region = interior & (region_lum[labels] >= TOOL_LUM_MIN)
    line_region = interior & (region_lum[labels] < LINE_LUM_MAX)
    print(f"tool texels: {int(tool_region.sum())}, engraved line texels: {int(line_region.sum())}")

    # Warp only the tool silhouette: it is a hand carved emblem, not a
    # machined joint, so its edge gets the organic treatment cobble stones
    # get. The trim's own edge is handled separately below, by row position,
    # because a lip along the top of a panel is straight.
    tool_id = np.where(tool_region, 1, 0)
    tool_hi = lib.warp_labels(tool_id, amp=2.5, seed=41)
    tool_edge = lib.region_edges(tool_hi)
    tool_dist = lib.distance_to_edge(tool_edge, max_dist=4)
    tool_t = np.clip(tool_dist / 4, 0.0, 1.0)
    tool_t = tool_t * tool_t * (3 - 2 * tool_t)
    tool_mask_hi = tool_hi > 0

    # The trim's edge, a smoothstep across the row 1 to row 2 join so the
    # step reads as a lip rather than a cliff.
    y = np.arange(SIZE)[:, None] / SIZE * 16.0
    trim_t = np.clip((2.0 - y) / 1.2 + 0.5, 0.0, 1.0)
    trim_t = trim_t * trim_t * (3 - 2 * trim_t)
    trim_t = np.broadcast_to(trim_t, (SIZE, SIZE))

    panel_level = 0.30
    tool_level = 0.52 + 0.06 * np.where(tool_mask_hi, 1.0, 0.0)
    trim_level = 0.78

    layout = panel_level * (1 - tool_t) + tool_level * tool_t
    layout = layout * (1 - trim_t) + trim_level * trim_t

    # The engraved linework threaded through the tool shape: fine grooves,
    # scored a little below whatever they sit on rather than a separate
    # height band, since that is what a scribed line on a carving is.
    line_hi = lib.upscale(line_region.astype(np.float32), smooth=False)
    line_hi = lib.blur(line_hi, 1)
    layout = layout - 0.10 * line_hi * (1 - trim_t)

    # Plank grain, shared with the top and side by using the same seeds:
    # subtle here since the carved motif carries most of the relief.
    grain = lib.fbm(SIZE, base_cells=20, octaves=3, seed=51, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=52), 1) * 0.03

    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: the trim wears smoothest (a hand's edge), the tool heads
    # read as steel and take their own flat sheen from the metal F0 rather
    # than this map's spread, the panel is duller and the engraved lines
    # collect grime and stay roughest of all.
    rough_noise = lib.fbm(SIZE, base_cells=18, octaves=3, seed=53)
    smooth = 0.35 * trim_t + 0.35 * tool_t * (1 - trim_t) + 0.4 * rough_noise
    smooth = smooth - 0.15 * line_hi * (1 - trim_t)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    # Tool heads read as steel: metal F0 on the raised, undarkened part of
    # the warped tool silhouette only, not the engraved lines cut into it.
    metal_mask = tool_mask_hi & (line_hi < 0.4) & (trim_t < 0.5)

    normal_strength = 16.0
    m = lib.pack(stem, sys.argv[1], albedo, height, smooth, CLS,
            normal_strength=normal_strength, metal_mask=metal_mask)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    lib.preview(sys.argv[1], stem, sys.argv[1] + "/" + stem + "_preview.png")
    return lines


def main():
    return build(STEM)


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
