"""Hand authored height and smoothness for default_sand.

The 16 px art is five grey shades of per texel dither, no two touching
texels reliably the same shade, which is grain, not drawing: there is
nothing here for lib.segments to find a region in (tried at every
tolerance below the point it collapses to one blob, texel count barely
falls). Blurring that dither at native resolution (radius 2, enough to
wash out the texel to texel jitter but not so much it flattens to
nothing) still leaves a real signal, standard deviation 0.022 against
0.056 raw: broad, several texel wide patches where the art sits a shade
or two lighter or darker than its neighbours. That is the sweep the brief
means, sand a little packed or a little duned, and it is the only large
scale structure this art has. Everything finer than that is grain, built
here rather than read off the art, since at 16 px a single texel is
already many real grains and the art was never drawn to show them.
"""

import sys

import numpy as np

import lib

STEM = "default_sand"
CLS = "sand"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    for tolerance in (0.02, 0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        print(f"segments at tolerance {tolerance}: n={n} "
              f"(no real regions, sand's colour is grain not drawing)")

    # The sweep: blur the native art hard enough to kill texel to texel
    # dither (radius 2, over half the 16 px width) but no harder, then a
    # smooth (bilinear) upscale so it arrives as a gentle continuous rise
    # and fall rather than the source's own texel edges.
    sweep16 = lib.blur(lum, 2)
    print(f"sweep sd at native res: {sweep16.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.upscale(sweep16, smooth=True)
    sweep = lib.normalise01(sweep)

    # Fine grain: sand's real structure, a texel or two of the 256 map
    # across, well under the native art's own 16 px texel. Two octaves so
    # it is not one single grain size, plus a separate finer dusting on
    # top for the texel to texel sparkle loose sand actually has.
    grain = lib.fbm(SIZE, base_cells=90, octaves=2, seed=31, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=32), 1)

    height = lib.normalise01(0.20 * sweep + 0.55 * grain + 0.35 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: uniformly rough, sand has no worn high face the way a
    # stone chip or a plank does, with only a faint variation from its own
    # noise field, a little of it following the grain so a grain's own
    # high side reads a touch less rough than the pit beside it.
    variation = lib.fbm(SIZE, base_cells=40, octaves=3, seed=33, gain=0.55)
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
