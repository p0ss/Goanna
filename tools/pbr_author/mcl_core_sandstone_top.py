"""Hand authored height and smoothness for mcl_core_sandstone_top.

The cut face: mean luminance 0.637, standard deviation only 0.027, far
tighter than the side (0.088) or the bottom (0.061). This is the flat
matrix of the cut, not a bed or a stone, and the art's small light and dark
flecks in it are subtle grain, not real pits or separate stones the way
default_stone's rougher mottle shows.

An earlier version of this script ran lib.segments over the art and domed
every fleck it found as its own small region, which read as tiling or
cracked pavement rather than a dressed stone face. A cut face like this one
stays flat: fine grain at grain scale plus a handful of sparse, shallow
pits, no region domes copying the art's own colour noise into the relief.

Shares its fine grain and pore noise with mcl_core_sandstone_normal and
_bottom (seeds 61, 62) so the three faces read as one stone.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_sandstone_top"
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

    # The cut face is flat, so the layout starts from a single baseline
    # rather than any labelling of the art. A sparse, coarse noise field
    # gives a handful of shallow pits, thresholded to keep only its lowest
    # few percent, so the face reads as a dressed stone with the odd worn
    # spot, not a field of them.
    baseline = 0.5
    pit_field = lib.fbm(SIZE, base_cells=6, octaves=2, seed=65, gain=0.5)
    pit_floor = np.percentile(pit_field, 6.0)
    pit_depth = np.clip(pit_floor - pit_field, 0.0, None)
    pit_depth = pit_depth / max(pit_depth.max(), 1e-6)
    print(f"pit coverage {(pit_depth > 0.05).mean() * 100:.1f}% of the face")

    # Fine grain and pores shared with the other two sandstone faces, kept
    # to a third of the side's weight: this face is the flat cut, not the
    # weathered ones.
    grain = lib.fbm(SIZE, base_cells=44, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.018
    pores = lib.blur(lib.white_noise(SIZE, seed=PORES_SEED), 1) * 0.018
    height = lib.normalise01(baseline + grain + pores - pit_depth * 0.22, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height with the face's own light variation: a cut
    # face wears evenly, so the spread is narrower than the other two
    # faces' own smoothness fields, and the pits themselves stay rougher.
    rough_noise = lib.fbm(SIZE, base_cells=26, octaves=3, seed=75, gain=0.55)
    smooth = 0.55 * height + 0.45 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 9.0
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
