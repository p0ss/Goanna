"""Hand authored LabPBR height and smoothness for crafting_workbench_front.

crafting_workbench_front.png and crafting_workbench_side.png are the same
file byte for byte (md5 515f613f81e6cf2c548ee3051ee30c50 both), so this
script and crafting_workbench_side.py build the same relief from the same
art; the game already draws the same picture on both faces.

The art is a plank panel with a narrow lighter trim across the very top two
rows (row means 0.618 and 0.570, against 0.29 to 0.48 for the rest) and, in
the fourteen rows below that, a motif drawn in darker lines threaded
through a slightly lighter silhouette (an hourglass shape, 28 texels at
0.466 and 16 texels at 0.43 against a 0.335 background, the outline of a
hanging handle rather than anything with a face). The first pass read the
lighter silhouette as a raised tool and gave it a metal F0, which is why
it looked like a steel head bolted to the panel. There is nothing raised
here: this rebuild keeps the panel flat throughout, plank grain only,
including the lighter hourglass silhouette itself (its colour is paint,
not height), and engraves only the art's own darkest texels (down to
0.253, well below the 0.335 background) as shallow grooves, since a
carved line is cut into the wood, not built up on top of it.
"""
import sys

import numpy as np

import lib

STEM = "crafting_workbench_front"
CLS = "wood"
SIZE = lib.SIZE

PANEL_HALF_WIDTH = 0.05   # the panel: flat, plank grain only
LINE_LUM_MAX = 0.30       # the art's own dark lines, below the background
LINE_DEPTH = 0.15         # a real, if shallow, engraved groove
LINE_CHAMFER = 1          # one texel: a scored line, not a bevel
TRIM_LEVEL = 0.68         # proud of the panel by a couple of texels
TRIM_GRAIN_AMP = 0.05

PANEL_GRAIN_SEED = 51     # shared with the top and side
PORE_SEED = 52
ROUGH_SEED = 53


def build(stem):
    src = lib.load_source(stem)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{stem}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    # The trim is exactly rows 0 and 1, found by row position rather than by
    # shade: it is a straight machined edge (the top lip of the panel
    # frame), not something a warp should soften.
    trim_row = np.zeros((16, 16), dtype=bool)
    trim_row[0:2, :] = True
    print(f"trim rows: {int(trim_row.sum())} texels")

    interior = ~trim_row
    line_region = interior & (lum < LINE_LUM_MAX)
    print(f"engraved line texels: {int(line_region.sum())}")

    # The trim's edge, blurred across the row 1 to row 2 join so the step
    # reads as a lip rather than a cliff. lib.blur wraps, so this stays
    # correct where the trim sits right across the tile's own seam (its
    # other edge, row 15 to row 0, is the wrap itself).
    trim_hi = lib.upscale(trim_row.astype(np.float32), smooth=False)
    trim_t = lib.blur(trim_hi, 3)

    # The panel: flat throughout, plank grain only. The hourglass motif's
    # own lighter paint is not built into the height at all, only its
    # darkest lines are, as a shallow engraved groove.
    panel_grain = (lib.fbm(SIZE, base_cells=20, octaves=3, seed=PANEL_GRAIN_SEED, gain=0.55) * 0.7
            + lib.blur(lib.white_noise(SIZE, seed=PORE_SEED), 1) * 0.3)
    panel_height = lib.band(panel_grain, half_width=PANEL_HALF_WIDTH)

    line_hi = lib.upscale(line_region.astype(np.float32), smooth=False)
    line_dist = lib.distance_to_edge(line_hi, max_dist=LINE_CHAMFER)
    line_dist = np.where(line_hi > 0.5, 0.0, line_dist)
    line_t = np.clip(line_dist / LINE_CHAMFER, 0.0, 1.0)
    line_t = line_t * line_t * (3 - 2 * line_t)
    panel_height = panel_height * line_t + (panel_height.mean() - LINE_DEPTH) * (1 - line_t)
    line_hi = lib.blur(line_hi, 2)

    trim_height = TRIM_LEVEL + lib.fbm(SIZE, base_cells=20, octaves=3,
            seed=PANEL_GRAIN_SEED, gain=0.55) * TRIM_GRAIN_AMP

    height = panel_height * (1 - trim_t) + trim_height * trim_t
    print(f"height sd {height.std():.3f}")

    # Smoothness: the trim wears smoothest (a hand's edge), the panel duller,
    # the engraved lines collect grime and stay roughest of all. Weighted
    # toward the material's own two dimensional grain rather than the
    # trim's row-only band, which on its own has no texture across the
    # columns at all and so reads (correctly) as a hard step wherever it
    # is compared against; the grain's real texture is what makes that
    # step tile properly.
    rough_noise = lib.fbm(SIZE, base_cells=18, octaves=3, seed=ROUGH_SEED)
    smooth = 0.5 + 0.5 * rough_noise + 0.10 * trim_t - 0.08 * line_hi * (1 - trim_t)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 14.0
    m = lib.pack(stem, sys.argv[1], albedo, height, smooth, CLS,
            normal_strength=normal_strength)
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
