"""Hand authored LabPBR height and smoothness for default_tnt_bottom.

The same wrapped paper family as default_tnt_side and default_tnt_top, six
shades all inside their 0.382 to 0.254 range, in the same broken period
four rhythm. Unlike the top, none of its darkest texels touch another:
sixteen separate single texel flecks under lum 0.28, no cluster the way
the top's fuse hole is a clean twelve texel group. The brief calls for a
fuse hole recessed on the top and bottom alike, but this art does not draw
one on the underside, only the ordinary wrap, so none is built here either;
a real stick of dynamite lights from the top, and Mineclonia's own art
agrees. Built as the same cosine fold as the side and top, no grain noise.
"""
import sys

import lib

import default_tnt_side as side

STEM = "default_tnt_bottom"
CLS = "wood"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    height = lib.band(side.paper_fold(), half_width=side.FOLD_HALF_WIDTH)
    print(f"height sd {height.std():.3f}")

    smooth_noise = lib.fbm(SIZE, base_cells=24, octaves=3, seed=side.SMOOTH_SEED, gain=0.55)
    smooth = 0.5 + 0.4 * smooth_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 10.0
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
