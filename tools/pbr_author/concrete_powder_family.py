"""Hand authored height and smoothness for the concrete powder family, one
module shared by all sixteen mcl_colorblocks_concrete_powder_<colour>
stems.

White concrete powder's art is a per texel dither, no two touching texels
reliably the same shade, standard deviation 0.0084, smaller than
default_sand's own 0.056 but the same idea: colour of a granular material,
not drawing, with nothing for lib.segments to find at any tolerance. Every
other colour dithers harder still (up to 0.028 for green) with the same
lack of drawn structure. That is default_sand.py's own case exactly, so
this reuses its approach: a blurred sweep from each colour's own art for
the broad packed-or-loose patches, fine synthetic grain and dust for the
texel scale sparkle the art itself is too coarse to show, one set of noise
seeds shared by every colour since it is the same granular material under
sixteen tints, and class "sand": lib.class_of reads "cloth" for these
stems (Mineclonia's footstep classification for anything soft underfoot),
but a powder is granular stone dust, not cloth, and the brief calls for
sand outright.
"""

import sys

import numpy as np

import lib

SIZE = lib.SIZE
COLOURS = ["black", "blue", "brown", "cyan", "green", "grey", "light_blue",
        "lime", "magenta", "orange", "pink", "purple", "red", "silver",
        "white", "yellow"]
CLS = "sand"

# default_sand.py's own seeds, shared by every colour: one granular
# material, sixteen tints.
SWEEP_BLUR_RADIUS = 2
GRAIN_SEED = 31
DUST_SEED = 32
VARIATION_SEED = 33
NORMAL_STRENGTH = 1.5


def run(stem, out_dir):
    src = lib.load_source(stem)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{stem}: lum mean {lum.mean():.3f} sd {lum.std():.4f} "
            f"class_of {lib.class_of(stem)} (using {CLS})")

    # The sweep: blur the native art hard enough to kill texel to texel
    # dither but no harder, then a smooth (bilinear) upscale so it arrives
    # as a gentle continuous rise and fall rather than the source's own
    # texel edges.
    sweep16 = lib.blur(lum, SWEEP_BLUR_RADIUS)
    print(f"sweep sd at native res: {sweep16.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.upscale(sweep16, smooth=True)
    sweep = lib.normalise01(sweep)

    # Fine grain: a granular material's real structure, a texel or two of
    # the 256 map across, well under the native art's own 16 px texel. Two
    # octaves so it is not one single grain size, plus a separate finer
    # dusting on top for the texel to texel sparkle loose powder has.
    grain = lib.fbm(SIZE, base_cells=90, octaves=2, seed=GRAIN_SEED, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=DUST_SEED), 1)

    height = lib.normalise01(0.20 * sweep + 0.55 * grain + 0.35 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    # Smoothness: uniformly rough, powder has no worn high face the way a
    # stone chip or a plank does, with only a faint variation from its own
    # noise field, a little of it following the grain so a grain's own
    # high side reads a touch less rough than the pit beside it.
    variation = lib.fbm(SIZE, base_cells=40, octaves=3, seed=VARIATION_SEED, gain=0.55)
    smooth = 0.25 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    # Nearest upscale keeps the same texel alignment the height field
    # itself was built against.
    albedo = lib.upscale(rgb)

    m = lib.pack(stem, out_dir, albedo, height, smooth, CLS,
            normal_strength=NORMAL_STRENGTH)
    print(f"normal_strength={NORMAL_STRENGTH}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    lib.preview(out_dir, stem, str(out_dir) + "/" + stem + "_preview.png")
    return lines


if __name__ == "__main__":
    sys.exit("run a per stem script, e.g. "
            "mcl_colorblocks_concrete_powder_white.py, not this module directly")
