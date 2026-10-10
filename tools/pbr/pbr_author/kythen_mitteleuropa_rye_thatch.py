"""Hand authored LabPBR height and smoothness for kythen_mitteleuropa_rye_thatch.

The 32 px art is a fine two tone dither, one dominant mid shade (0.655)
carrying a scatter of a darker (0.437) and a brighter (0.701) fleck on
roughly one texel in four, no coherent block or course the way
kythen_habesha_thatch.py's own battens and course shadow give it: row
means run 0.600 to 0.616 and column means 0.600 to 0.615, both too flat to
read a batten or a course boundary back from. This is loose bundled straw
drawn as a stochastic dither rather than a drawn structure, so the relief
is built from that dither directly: its own dark texels, nearest upscaled
and stretched down the tile, are the gaps between individual stalks, laid
downward the way the brief calls for.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_rye_thatch"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, the same helper
    kythen_habesha_thatch.py and default_tree.py use to stretch grain."""
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
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("row means:", np.round(lum.mean(axis=1), 3))
    print("col means:", np.round(lum.mean(axis=0), 3))

    # The art's own dither has no coherent macro signal to read a layout
    # back from (see the docstring), so unlike kythen_khmer_earthenware_tile.py
    # this is not built by upscaling the art's own luminance: a nearest
    # upscale of a stochastic dither repeats each source texel eight times
    # across, and stretching that block pattern down the tile gave a false
    # seam every time it was tried, one raw texel's own noisy edge landing
    # on the tile's wrap by chance. The relief comes from directional noise
    # instead, tileable by construction, at the same vertical grain scale a
    # bundle of stalks laid downward would show: a broad grain and a finer
    # streak on top, the same construction kythen_habesha_thatch.py and
    # default_tree.py use for stalks and bark running the length of a
    # surface.
    grain_src = lib.fbm(SIZE, base_cells=20, octaves=3, seed=911, gain=0.55)
    grain = blur_axis(grain_src, radius=14, axis=0)
    fine_src = lib.fbm(SIZE, base_cells=52, octaves=3, seed=912, gain=0.55)
    fine = blur_axis(fine_src, radius=2, axis=0)

    field = 0.35 * grain + 0.65 * fine
    height = lib.normalise01(field, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: loose straw is fairly rough throughout, a little glossier
    # on the raised stalk tops than in the gaps between them, its own
    # directional streakiness riding on top.
    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=20, octaves=3, seed=913, gain=0.55), radius=10, axis=0)
    smooth = 0.45 * height + 0.5 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 6
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0], fine_detail=1.0)
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
