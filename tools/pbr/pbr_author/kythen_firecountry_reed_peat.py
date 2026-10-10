"""Hand authored height and smoothness for kythen_firecountry_reed_peat.

The 32 px art has no drawn stones the way default_dirt's own dither does:
lib.segments only finds real structure at a loose tolerance (0.08, 47
regions, one 689 texel matrix and the rest small patches), and most of
that matrix is one broad mat rather than separate clods. This is reed
peat, packed fibrous matter, soft underfoot, so the relief here leans on
tangled fibre streaks at random angles rather than default_dirt's own
clod domes, with only the darker patches (the matrix's own low points)
carved down as real depressions where the mat has settled.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_reed_peat"
CLS = "soil"
SIZE = lib.SIZE


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
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")

    for tolerance in (0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = np.bincount(labels.ravel())
        print(f"segments at tolerance {tolerance}: n={n} biggest={int(sizes.max())}")

    # A broad guide from the art's own brightness: the mat's own high and
    # low patches, smoothly upscaled rather than read as separate clods.
    guide = lib.normalise01(lib.blur(lib.upscale(lum, smooth=True), 2))

    # Tangled fibre: two independent streak fields at different angles
    # (not axis aligned the way wood grain is, since reed lies down in
    # whatever direction it was trodden), each a long, thin smear.
    fibre_a = blur_axis(lib.fbm(SIZE, base_cells=28, octaves=2, seed=231, gain=0.5), radius=10, axis=1)
    fibre_b = blur_axis(lib.fbm(SIZE, base_cells=28, octaves=2, seed=232, gain=0.5), radius=10, axis=0)
    fibre = 0.6 * fibre_a + 0.6 * fibre_b

    # A softer, coarser lump above the fibre scale, the mat settling into
    # gentle hummocks.
    lumps = lib.fbm(SIZE, base_cells=9, octaves=3, seed=233, gain=0.55) * 0.30

    layout = 0.30 * guide + 0.35 * lumps + 0.35 * fibre

    # Below the texel: fine loose fibre ends, and a scatter of deeper
    # settled hollows where the mat has compressed most, carrying the
    # jointed ao rule.
    fuzz = lib.blur(lib.white_noise(SIZE, seed=234), 1) * 0.05
    hollow_field = lib.blur(lib.white_noise(SIZE, seed=235), 2)
    hollow_cut = float(np.percentile(hollow_field, 30))
    hollows = np.where(hollow_field < hollow_cut, hollow_field - hollow_cut, 0.0) * 2.4

    height = lib.normalise01(layout + fuzz + hollows, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: soft and matte, wide spread since a fibre mat wears
    # unevenly, a little smoother on the raised hummocks.
    variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=236, gain=0.55)
    smooth = 0.30 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 12.0
    height = lib.band(height, 0.42)
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
