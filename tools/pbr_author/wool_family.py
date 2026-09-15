"""Shared build for the sixteen wool dyes, one script per stem calling
run(stem, out_dir).

wool_white's art is a per texel dither, five or six grey steps, with no
region for lib.segments to find (as with default_sand.py's own sand, tried
and rejected the same way). Checked by hand: every dyed wool's own
normalised luminance correlates above 0.93 with wool_white's, so the
sixteen textures are one dither recoloured, not sixteen different weaves.
That means building the height field from each stem's own art already
gives the same relief in every colour, and the noise layered over it uses
the same seeds for all sixteen regardless, so nothing about the weave
drifts with the dye. Only the albedo differs; the colour is the art.
"""

import numpy as np

import lib

CLS = "cloth"
SIZE = lib.SIZE


def run(stem, out_dir):
    src = lib.load_source(stem)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    lo, hi = float(lum.min()), float(lum.max())
    norm_lum = (lum - lo) / max(hi - lo, 1e-6)
    print(f"{stem}: lum min {lo:.3f} max {hi:.3f} mean {lum.mean():.3f}")

    # Layout: the art's own light and dark, smoothly upscaled so the tufts
    # the artist drew stay where they are, rounded rather than square
    # edged. This is where "the art's light and dark" enters; everything
    # below is fixed noise, same seeds for every dye.
    layout = lib.upscale(norm_lum, smooth=True)
    layout = lib.blur(layout, 2)

    # Fibre bundles: soft rounded lumps a couple of texels across, the
    # weave's own bundle structure, wrapping the layout without ever
    # cutting a sharp edge into it.
    bundles = lib.fbm(SIZE, base_cells=44, octaves=2, seed=401, gain=0.5)
    bundles = lib.blur(bundles, 2)

    # Fuzz: loose fibre finer than the bundles, sitting on top.
    fuzz = lib.blur(lib.white_noise(SIZE, seed=402), 1)

    height = 0.55 * layout + 0.30 * bundles + 0.15 * fuzz
    # A further blur so no edge in the stack, layout's own upscale
    # included, ever reads as a hard step; wool has no sharp edges.
    height = lib.blur(height, 1)
    height = lib.normalise01(height, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: matte everywhere, only a faint variation, mostly the
    # material's own noise with a whisper following height so a bundle's
    # own crown reads a touch less rough than the crevice beside it.
    variation = lib.fbm(SIZE, base_cells=52, octaves=2, seed=403, gain=0.5)
    smooth = 0.15 * (height - height.mean()) + 0.5 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 3.5
    m = lib.pack(stem, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    lib.preview(out_dir, stem, str(out_dir) + "/" + stem + "_preview.png")
    return lines
