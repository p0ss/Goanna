"""Hand authored LabPBR height and smoothness for kythen_mitteleuropa_loom_frame.

The 32 px art carries eight grey shades. The two darkest run full height
down eight columns spaced exactly four texels apart (0, 4, 8, ... 28), each
step between a post column and its neighbour a jump of 0.2 or more in mean
luminance against steps of 0.02 or less everywhere else: eight slender
timber uprights, the loom's frame. Between each pair of posts, three
texels carry a fine, close checkerboard of two near shades (0.575 and
0.582), the strung threads read as a faint weave rather than a solid
infill panel, the same two-close-shades dither kythen_habesha_wattle.py's
own weave shows. The frame reads straight from the art's own luminance for
its faceted post and bay shape, the same call kythen_khmer_earthenware_tile.py
and kythen_mitteleuropa_oak_timber.py make, with a real narrow trench cut
at each post for the ao a joint needs and the thread checkerboard carried
through as a fine crosswise ripple on top.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_loom_frame"
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
    # so the seam metric's single wrap comparison lands on a post's own
    # steepest point rather than an ordinary bay, the same false alarm
    # default_cobble.py's docstring describes. Rolling moves the wrap to
    # the pair of columns with the smallest step in the art's own column
    # means (columns 6 and 7, a jump of 0.002) instead.
    src = np.roll(src, -7, axis=1)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    col_mean = lum.mean(axis=0)
    print("column mean lum:", np.round(col_mean, 3))

    art = src.shape[0]
    up = SIZE // art
    post_cols = col_mean < (col_mean.min() + 0.06)
    print("post columns:", np.where(post_cols)[0].tolist())

    # The bay's own shape, straight from a wrapped smooth upscale of the
    # art's luminance, the same call kythen_khmer_earthenware_tile.py and
    # kythen_mitteleuropa_oak_timber.py make: the art already draws the
    # post and the thread checkerboard between them.
    norm_lum = (lum - lum.min()) / max(lum.max() - lum.min(), 1e-6)
    bay = lib.blur(lib.upscale(norm_lum, smooth=True), 1)

    # A real narrow trench at each post, a flat low floor rather than a
    # v-shaped dip, the same construction the ashlar and oak board and oak
    # timber stems use for their own single art texel joints.
    post_hi = np.repeat(post_cols, up)[None, :].repeat(SIZE, axis=0)
    max_dist = 1
    dist = lib.distance_to_edge(post_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=30, octaves=2, seed=961) * 0.5
    dist = np.where(post_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    groove_t = np.clip(dist / max_dist, 0.0, 1.0)
    groove_t = groove_t * groove_t * (3 - 2 * groove_t)
    groove = -0.9 * (1.0 - groove_t)

    # Fine vertical grain on the posts (a hewn upright) and the thread
    # checkerboard's own crosswise ripple, a period four wave in both
    # directions on the bay texels only, matching the art's own weave.
    grain_src = lib.fbm(SIZE, base_cells=22, octaves=3, seed=962, gain=0.55)
    grain = blur_axis(grain_src, radius=12, axis=0) * 0.06

    period = 4 * up
    xs = np.arange(SIZE)[None, :]
    ys = np.arange(SIZE)[:, None]
    thread = (0.5 * (1.0 - np.cos(2 * np.pi * (xs % period) / period))
              + 0.5 * (1.0 - np.cos(2 * np.pi * (ys % period) / period)))
    thread = np.where(post_hi, 0.0, thread) * 0.04

    pores_src = lib.blur(lib.white_noise(SIZE, seed=963), 1)
    pores = blur_axis(pores_src, radius=4, axis=0) * 0.02

    layout = 0.4 * bay + groove + grain + thread + pores
    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the groove and the bay's own shape: the post seam
    # gathers dust and stays rough, the threads and the worked post faces
    # wear smoother, the frame's own patchy variation on top.
    rough_noise = lib.fbm(SIZE, base_cells=18, octaves=3, seed=964, gain=0.55)
    smooth = 0.4 * groove_t + 0.35 * bay + 0.4 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 18.0
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
