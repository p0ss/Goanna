"""Hand authored height and smoothness for mcl_core_log_birch, papery bark.

Birch does not have this family's column furrows at all: every column mean
is close to every other (0.45 to 0.86, mostly 0.7 to 0.86), and the one
column that would pass the other three scripts' flat-and-dark test, column
0 (std 0.037, the lowest in the tile), is barely darker than the rest
(mean 0.578 against an overall mean of 0.731). There is no groove cut into
this bark; what the art actually draws is scattered dark marks, six shades
below the general bark tone (0.386, against paper tones from 0.553 up), at
scattered single texels and short runs: 27 of the 256 texels, 10.5 percent
of the tile. Those are lenticels, the horizontal breathing pores real birch
bark carries, and the instruction that birch bark is smooth and papery with
its lenticels as shallow horizontal scars describes this art exactly: dark
marks on an otherwise even field, not a furrowed surface.

So this script's structure is built from those marks, not from columns.
lib.warp_labels rounds their pixel edges into organic marks and
lib.region_edges plus lib.distance_to_edge turn each mark into a shallow
dish rather than a stepped block, the same distance transform the top
scripts use for their bark ring, which the wrapped BFS in
lib.distance_to_edge handles correctly at the tile seam in a way an ad hoc
blur of the raw mask does not: an early version of this script built the
dish directly from a blurred copy of the mask and it seamed badly, because
only a handful of the sixteen native rows actually carry a mark and the
rest are perfectly flat, diluting the "typical" row to row change the seam
check compares against and making the one real seam-crossing mark, which
this art happens to have, read as an outsized jump. Stretching that dish
along x elongates each mark into the "horizontal scar" the art is showing.

Smoothness leans on the same dish, heavily blurred along the log's axis so
it does not inherit that same seam problem, plus this script's own
directional roughness, weighted well above the dish itself so the field's
seam behaviour follows the well behaved term rather than the risky one.

The top texture (mcl_core_log_birch_top.py) shares this script's seed.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_log_birch"
CLS = lib.class_of(STEM)
SIZE = lib.SIZE
SEED = 401


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, to stretch a feature along the
    other axis. lib.blur does both axes; the scar elongation needs only
    one."""
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    # A clean gap: 0.386 is the lenticel shade, the next shade up is 0.553,
    # a jump of 0.167. 0.5 sits in that gap.
    dark_thresh = 0.5
    mask16 = (lum < dark_thresh).astype(int)
    print(f"lenticel texels: {mask16.sum()} / 256 ({mask16.mean() * 100:.1f} percent)")

    # Round the marks' pixel edges rather than leaving them square, then
    # turn each one into a shallow dish with lib.region_edges and
    # lib.distance_to_edge's wrapped distance transform, which handles the
    # tile seam correctly (see the module docstring for why a plain blur of
    # the mask does not).
    labels_hi = lib.warp_labels(mask16, size=SIZE, amp=3.0, seed=SEED, cells=12)
    edges = lib.region_edges(labels_hi)
    edge_max_dist = 6
    dist = lib.distance_to_edge(edges, max_dist=edge_max_dist)
    t = np.clip(dist / edge_max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    dish = (1 - t) * labels_hi  # 0 outside every mark, deepest at a mark's centre

    # Elongate along x: a lenticel is a horizontal scar, not a round pit.
    scar = blur_axis(dish, radius=6, axis=1)
    print(f"scar min {scar.min():.3f} max {scar.max():.3f} mean {scar.mean():.3f}")

    # Fine grain, much weaker than the other three species: birch bark is
    # smooth, it is not furrowed, so this is texture rather than structure.
    grain_src = lib.fbm(SIZE, base_cells=10, octaves=3, seed=SEED + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=6, axis=0) * 0.10

    pores_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1)
    pores = pores_src * 0.02

    layout = 0.70 - 0.40 * scar
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: bark stays smooth except right at a scar, plus this
    # script's own directional streakiness, which is given the larger
    # weight so the field's seam behaviour comes from the well behaved
    # continuous term rather than from scar, whose own raw seam ratio the
    # module docstring measured as poor no matter how it is blurred.
    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=14, octaves=3, seed=SEED + 5, gain=0.55), radius=6, axis=0)
    smooth = 0.60 - 0.25 * scar + 0.50 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 26.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS, normal_strength=normal_strength)
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
