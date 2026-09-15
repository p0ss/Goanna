"""Hand authored LabPBR height and smoothness for default_furnace_top.

default_furnace_top.png and default_furnace_bottom.png are the same file
(five shades, 0.462 to 0.681, the same grey stone as the side but a
narrower range and no dark opening cut into it), so default_furnace_bottom
calls this script's build with its own stem.

Unlike the side, no shade threshold here closes a joint line: even the
darkest single shade alone (31 of 256 texels) sits in two small, unlinked
clusters, and the next threshold up swallows half the face. This is one
stone slab, not dressed courses, so it gets no joint network at all, just
the same flat band and fine grain default_furnace_side.py builds, carrying
the darkest shade as sparse weathered flecks rather than forcing it into a
joint the art does not draw. See default_furnace_side.py for the shared
build and its GRAIN_SEED family.
"""
import sys

import lib

import default_furnace_side as body

STEM = "default_furnace_top"
CLS = "stone"

TOP_MORTAR_THRESH = 0.4845  # the darkest shade alone: see module docstring


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    height, smooth = body.build_body(STEM, src, TOP_MORTAR_THRESH)
    print(f"height sd {height.std():.3f}")
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 16
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
