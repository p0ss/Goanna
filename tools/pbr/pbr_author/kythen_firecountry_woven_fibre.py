"""Hand authored height and smoothness for kythen_firecountry_woven_fibre.

Row means and column means carry the identical signature: every fourth
line (0, 4, 8, ... 28) sits low, 0.41, and the three lines after it climb,
0.61, 0.64, 0.66, in both directions at once. That is a basket weave drawn
as repeated strand cells, four texels along each axis, a dark crease
where one strand ducks under its neighbour and a rounded, brightening
top as it rises back up before the next crease. Because the pattern is
the same in both directions, the height here is built straight from the
art's own row and column brightness (the two directions averaged into one
profile, since they read identically), replicated across the tile the
weave's own period the way sandstone's strata are replicated, not warped:
this is a manufactured plait with a genuinely straight grid, and bending
its crease lines would turn a woven mat into a scribble.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_woven_fibre"
CLS = "leaves"
SIZE = lib.SIZE
ART = 32
PERIOD = 4


def blur_axis(field, radius, axis):
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
    print("source", STEM, src.shape)
    print("lib.class_of reads:", lib.class_of(STEM, GAME))
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    row_means = lum.mean(axis=1)
    col_means = lum.mean(axis=0)
    print("row means:", np.round(row_means, 3).tolist())
    print("col means:", np.round(col_means, 3).tolist())

    # One strand-cell profile, four texels long, averaged from both
    # directions and all eight repeats, since row and column agree.
    phase_vals = np.concatenate([row_means.reshape(-1, PERIOD), col_means.reshape(-1, PERIOD)])
    profile = phase_vals.mean(axis=0)
    lo, hi = profile.min(), profile.max()
    profile = (profile - lo) / max(hi - lo, 1e-6)
    print("one strand-cell profile (crease to crest):", np.round(profile, 3).tolist())

    row_profile = np.tile(profile, ART // PERIOD)
    col_profile = np.tile(profile, ART // PERIOD)
    row_hi = np.repeat(row_profile, SIZE // ART)
    col_hi = np.repeat(col_profile, SIZE // ART)

    # The two strand directions combined by average, then rounded: the art
    # already draws the ramp inside each cell as three sub-shades, so a
    # light isotropic blur only rounds the texel steps of the 32 to 256
    # upscale into a strand's real curved cross section, it does not
    # invent a new shape.
    weave = 0.5 * row_hi[:, None] + 0.5 * col_hi[None, :]
    weave = lib.blur(weave, 2)

    # Fibre grain inside each strand, running along the strand's own
    # length: the row strands (weft) get grain stretched along x, the
    # column strands (warp) get grain stretched along y, both present at
    # once the way a real plait shows fibre both ways.
    weft_grain = blur_axis(lib.fbm(SIZE, base_cells=48, octaves=2, seed=301, gain=0.5), radius=6, axis=1)
    warp_grain = blur_axis(lib.fbm(SIZE, base_cells=48, octaves=2, seed=302, gain=0.5), radius=6, axis=0)
    grain = 0.5 * weft_grain + 0.5 * warp_grain

    fuzz = lib.blur(lib.white_noise(SIZE, seed=303), 1) * 0.03

    height = lib.normalise01(0.78 * weave + 0.16 * (grain * 0.5 + 0.5) + fuzz, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: strand crests wear a slight sheen, the
    # crease where one strand ducks under the other stays matte, the
    # fibre's own variation riding on top.
    variation = lib.fbm(SIZE, base_cells=26, octaves=3, seed=304, gain=0.55)
    smooth = 0.35 * (height - height.mean()) + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 11.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
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
