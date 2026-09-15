"""Hand authored height and smoothness for mcl_core_grass_side_snowed.

The art is two materials in one tile, split almost exactly in half by row:
rows 0 to 6 are snow, 0.81 to 0.95 luminance, rows 8 to 15 are dirt, 0.30
to 0.44, default_dirt.py's own range; row 7 is the one row where the two
dither together, fourteen snow texels and two that have already dropped
to dirt. Thresholding luminance at 0.60 recovers that split exactly: 124
of 256 texels snow, a clean horizontal band with only row 7's own two
texels breaking it.

lib.class_of reads this back as "snow" (its subsurface byte, 103, is an
exact match for CLASS_SSS's own snow entry), which is defensible, roughly
half the tile by area is snow and "snow" is also the name in the stem, but
it is a compromise: the other half is plainly default_dirt.py's own
material, not snow with dirt coloured pixels. Building it as one class
would either give the dirt half a snow class's shallow parallax depth and
scattering byte, or give the snow half dirt's, so instead the height and
smoothness are built as default_dirt.py's own recipe below the split and
default_snow.py's own recipe above it, each sharing that script's own
noise seeds (dirt: 21 lumps, 22 grit, 23 pits, 24 variation, the default
warp seed 7; snow: 601 drift, 602 sparkle, 603 variation) so this block
reads as the same materials default_dirt.py and default_snow.py already
build, not a third invented one, and joins its neighbours when a
dirt_with_grass_snow block sits next to plain dirt or plain snow. Only
the final pack takes one class, "snow", kept from class_of because the
alternative (overriding to "soil") is no less a compromise and snow is
what class_of and the stem name agree on.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_grass_side_snowed"
CLS = "snow"
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def build(out_dir):
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f}")

    snow16 = (lum > 0.60).astype(int)
    print(f"snow texels: {int(snow16.sum())} of {snow16.size}, row by row:")
    for y, row in enumerate(snow16):
        print(" ", y, "".join(str(v) for v in row))

    # A soft, organically bent boundary between the two materials, from the
    # same warp device every region boundary in this project uses, rather
    # than the flat 256 px band the raw 16 px split would give it.
    snow_hi = lib.warp_labels(snow16, amp=3.0, seed=41, cells=8).astype(np.float32)
    snow_frac = lib.blur(snow_hi, 2)

    # --- the dirt half, default_dirt.py's own recipe and seeds -------------
    # Snow texels are filled with the dirt area's own mean colour first, so
    # lib.segments finds structure only among the real dirt texels; the
    # snow blob would otherwise dominate its own region and there is no
    # dirt there to segment anyway, it is masked out below.
    dirt_mean = rgb[snow16 == 0].mean(axis=0)
    rgb_dirt = np.where(snow16[..., None] == 1, dirt_mean, rgb)
    lum_dirt = lib.luminance(rgb_dirt)
    tolerance = 0.05
    labels, n = lib.segments(rgb_dirt, tolerance=tolerance)
    region_lum = np.array([lum_dirt[labels == i].mean() for i in range(n)])
    print(f"dirt segments: n={n} tolerance={tolerance}")

    lo, hi = region_lum.min(), region_lum.max()
    target = 0.15 + 0.65 * (region_lum - lo) / max(hi - lo, 1e-6)
    labels_hi = lib.warp_labels(labels)  # default seed 7, default_dirt.py's own
    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    dirt_layout = narrow + 1.1 * (narrow - wide)

    edges = lib.region_edges(labels_hi)
    dist = lib.distance_to_edge(edges, max_dist=4)
    t = np.clip(dist / 4.0, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    lumps = lib.fbm(SIZE, base_cells=10, octaves=3, seed=21, gain=0.55) * 0.30
    grit = lib.blur(lib.white_noise(SIZE, seed=22), 1) * 0.05
    pits = lib.blur(lib.white_noise(SIZE, seed=23), 2) * 0.04
    dirt_height = lib.normalise01(dirt_layout + lumps + grit + pits, 0.5, 99.5)

    variation_dirt = lib.fbm(SIZE, base_cells=18, octaves=3, seed=24, gain=0.55)
    dirt_smooth = 0.45 * t + 0.55 * variation_dirt

    # --- the snow half, default_snow.py's own recipe and seeds -------------
    albedo = lib.upscale(rgb)
    lum256 = lib.luminance(albedo)
    guide = lib.normalise01(lib.blur(lum256, 3))
    drift = lib.fbm(SIZE, base_cells=5, octaves=3, seed=601, gain=0.5)
    drift = lib.blur(drift * 0.5 + 0.5, 3)
    grains = lib.white_noise(SIZE, seed=602)
    threshold = np.percentile(grains, 96.0)
    sparkle = np.clip((grains - threshold) / (grains.max() - threshold), 0.0, 1.0)
    sparkle = lib.blur(sparkle, 1)
    snow_height = lib.normalise01(0.62 * drift + 0.28 * guide + 0.22 * sparkle)

    variation_snow = lib.fbm(SIZE, base_cells=6, octaves=2, seed=603, gain=0.5)
    snow_smooth = 0.5 + 0.11 * zscore(variation_snow) + 0.35 * sparkle

    # --- blend by the art's own split --------------------------------------
    height = dirt_height * (1.0 - snow_frac) + snow_height * snow_frac
    height = np.clip(height, 0.0, 1.0)
    smooth = dirt_smooth * (1.0 - snow_frac) + snow_smooth * snow_frac
    print(f"height sd {height.std():.3f}, snow fraction {snow_frac.mean():.3f}")

    normal_strength = 6.0
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
    lines = build(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
