"""Hand authored LabPBR height and smoothness for kythen_mitteleuropa_oak_timber.

The 32 px art carries four grey shades. The darkest, 0.317, runs full
height down four columns spaced exactly eight texels apart (0, 8, 16, 24):
a row of four hewn timber posts standing side by side. Each eight texel bay
between two posts reads B D D C C C D D (0.341, 0.582, 0.582, 0.437, 0.437,
0.437, 0.582, 0.582): the post itself is the darkest column, a bright
chamfer (the brightest shade) catches the light immediately either side of
it, and the middle three texels sit at a duller mid shade, the flatter
hewn face between the two chamfers. That greyscale already draws the
timber's own cross section, a shallow faceted profile rather than a flat
sawn board, the same reading kythen_khmer_earthenware_tile.py gives its
own barrel roof: the relief comes straight from a smoothed upscale of the
art's luminance, with a real narrow groove cut at the post seams on top for
the ao a joint needs, since a bilinear upscale alone softens that seam more
than a hewn timber's own edge should be.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_oak_timber"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, the same helper default_tree.py
    uses to stretch grain along the length of a log."""
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}, class_of reads {CLS}")
    # The art tiles, but not at texel (0, 0): a post sits right on column 0,
    # so the seam metric's single wrap comparison lands on a joint's own
    # steepest point rather than an ordinary bay interior, the same false
    # alarm default_cobble.py's docstring describes. Rolling by half a bay
    # moves the wrap into a bay's own flat middle instead; the surface is
    # the same closed loop either way.
    src = np.roll(src, 4, axis=1)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    col_mean = lum.mean(axis=0)
    print("column mean lum:", np.round(col_mean, 3))

    art = src.shape[0]
    up = SIZE // art
    post_cols = col_mean < (col_mean.min() + 0.05)
    print("post columns:", np.where(post_cols)[0].tolist())

    # The bay's own faceted cross section, straight from a wrapped smooth
    # upscale of the art's luminance: the art already draws the chamfer and
    # the flatter mid face, so this is read rather than reinvented, the
    # same call kythen_khmer_earthenware_tile.py makes for its barrel roof.
    # lib.blur wraps by construction; PIL's own bilinear resize does not
    # know the tile wraps, which is why the smoothing goes through it.
    norm_lum = (lum - lum.min()) / max(lum.max() - lum.min(), 1e-6)
    bay = lib.blur(lib.upscale(norm_lum, smooth=True), 1)

    # A real narrow trench at each post seam, a flat low floor rather than
    # a v-shaped dip, the same construction the ashlar and oak board stems
    # use for their own single-art-texel joints: that is what gives the ao
    # a joint needs, which the bilinear barrel shape alone does not.
    post_hi = np.repeat(post_cols, up)[None, :].repeat(SIZE, axis=0)
    max_dist = 1
    dist = lib.distance_to_edge(post_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=30, octaves=2, seed=891) * 0.6
    dist = np.where(post_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    groove_t = np.clip(dist / max_dist, 0.0, 1.0)
    groove_t = groove_t * groove_t * (3 - 2 * groove_t)
    groove = -0.9 * (1.0 - groove_t)

    # Adze marks running the length of the post, the timber's grain: an
    # isotropic field blurred along y only, the same axis default_tree.py
    # and kythen_mitteleuropa_oak_board.py stretch their own vertical grain
    # along.
    grain_src = lib.fbm(SIZE, base_cells=20, octaves=3, seed=892, gain=0.55)
    grain = blur_axis(grain_src, radius=14, axis=0) * 0.06

    pores_src = lib.blur(lib.white_noise(SIZE, seed=893), 1)
    pores = blur_axis(pores_src, radius=5, axis=0) * 0.025

    layout = 0.4 * bay + groove + grain + pores
    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the groove and the bay's own shape: the post seam
    # gathers dust and stays rough, the chamfer is what wears smooth, the
    # timber's own patchy variation on top.
    rough_noise = lib.fbm(SIZE, base_cells=18, octaves=3, seed=894, gain=0.55)
    smooth = 0.4 * groove_t + 0.35 * bay + 0.4 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 16
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=art)
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
