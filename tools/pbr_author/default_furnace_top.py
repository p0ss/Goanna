"""Hand authored LabPBR height and smoothness for default_furnace_top.

default_furnace_top.png and default_furnace_bottom.png are the same file
(five shades, 0.462 to 0.681, the same grey stone as the side but a
narrower range and no dark opening cut into it), so default_furnace_bottom
calls this script's build with its own stem. Same segment, warp, dome
cobble treatment as the side and front, at a finer tolerance: the shade
range here is under half the side's, so 0.06 collapses almost the whole
face into one region (173 of 256 texels) while 0.03 keeps a 71 texel field
plus a real scatter of smaller stones, closer to what the side's regions
look like relative to its own range.
"""
import sys

import numpy as np

import lib

import default_furnace_side as body

STEM = "default_furnace_top"
CLS = "stone"
SEG_TOLERANCE = 0.03


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    old_tol = body.SEG_TOLERANCE
    body.SEG_TOLERANCE = SEG_TOLERANCE
    try:
        height, smooth = body.build_body(STEM, src, seed_base=10)
    finally:
        body.SEG_TOLERANCE = old_tol
    height = lib.normalise01(height, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 18
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
