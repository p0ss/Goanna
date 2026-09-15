"""Hand authored height and smoothness for mcl_core_red_sand.

The 16 px art is five grey shades of per texel dither, mean luminance 0.604,
standard deviation 0.051, the same character as default_sand's own art: no
two touching texels are reliably the same shade, and lib.segments collapses
to a single region by tolerance 0.08 (checked at 0.02, 0.05, 0.08), so there
is no drawn layout to read a stone or a clod out of. Blurred at native
resolution (radius 2) the dither still carries a real signal, standard
deviation 0.019 against 0.051 raw: broad patches a shade lighter or darker
than their neighbours, the same gentle sweep default_sand's own script
found and the brief calls the ripples in this sand. Everything finer than
that sweep is grain, built rather than read off the art, for the same
reason default_sand gives: a 16 px texel is already many real sand grains.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_red_sand"
CLS = "sand"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    for tolerance in (0.02, 0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        print(f"segments at tolerance {tolerance}: n={n} "
              f"(no real regions, this is grain dither like default_sand)")

    # The sweep: blur the native art hard enough to kill texel to texel
    # dither but no harder, then a smooth upscale so it arrives as a gentle
    # rise and fall rather than the source's own texel edges.
    sweep16 = lib.blur(lum, 2)
    print(f"sweep sd at native res: {sweep16.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.upscale(sweep16, smooth=True)
    sweep = lib.normalise01(sweep)

    # Fine grain: red sand's real structure, a texel or two of the 256 map
    # across, well under the native art's own 16 px texel. Two octaves so
    # it is not one grain size, plus a finer dusting on top for the loose
    # texel to texel sparkle.
    grain = lib.fbm(SIZE, base_cells=90, octaves=2, seed=131, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=132), 1)

    height = lib.normalise01(0.20 * sweep + 0.55 * grain + 0.35 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: uniformly rough, red sand has no worn high face the way a
    # stone chip does, with only a faint variation from its own noise
    # field, a little of it following the grain so a grain's own high side
    # reads a touch less rough than the pit beside it.
    variation = lib.fbm(SIZE, base_cells=40, octaves=3, seed=133, gain=0.55)
    smooth = 0.25 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the same texel alignment the height field
    # itself was built against.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 1.5
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
