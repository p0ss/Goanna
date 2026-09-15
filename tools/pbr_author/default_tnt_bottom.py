"""Hand authored LabPBR height and smoothness for default_tnt_bottom.

The same wrapped paper family as default_tnt_side and default_tnt_top, six
shades all inside their 0.382 to 0.254 range, in the same broken period
four rhythm. Unlike the top, none of its darkest texels touch another:
sixteen separate single texel flecks under lum 0.28, no cluster the way
the top's fuse hole is a clean twelve texel group. The brief calls for a
fuse hole recessed on the top and bottom alike, but this art does not draw
one on the underside, only the ordinary wrap, so none is built here either;
a real stick of dynamite lights from the top, and Mineclonia's own art
agrees. Built the same way as the wrap on the other two faces, straight
from its own shading.
"""
import sys

import numpy as np

import lib

STEM = "default_tnt_bottom"
CLS = "wood"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique lum:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    lum_hi = lib.upscale(lum, smooth=False)
    layout = 0.35 + 0.45 * lib.blur(lum_hi, 2)

    fibre = lib.fbm(SIZE, base_cells=30, octaves=3, seed=111, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=112), 1) * 0.03
    layout = layout + fibre + pores

    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=113, gain=0.55)
    smooth = 0.5 * (1 - height) + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 8.0
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
