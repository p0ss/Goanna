"""Hand authored height and smoothness for kythen_moana_stream_water.

The 32 px art is fully opaque, a low contrast dither (lum 0.435 to 0.598,
mean 0.517) with no directional structure: column and row means both
wander in a narrow band with no ramp, no furrow, no weave period, the
random surface glint of moving water rather than a drawn material. This is
a liquid tile, so the height stays in a small band about the middle (see
lib.band, used the way a fired tile or a cast slab is elsewhere in this
set) rather than the full class depth a stone joint gets: a stream's own
surface has gentle ripples, never a mortar groove's worth of relief.
class_of reads this back as "soil" from the bake (water evidently shares
soil's own low smoothness level there, a bake mismatch this brief allows
overriding); "glass" is used instead, since a liquid's own high, even
smoothness with a dielectric F0 is what LabPBR's glass class actually
gives it, not stone or soil's rough matte level.

lib.check has no tilt band for glass, so it falls back to the default
fifteen to thirty degrees, stone and soil territory. That is not a real
target for open water: the whole point of lib.band is to keep the tilt
nowhere near the class depth of a mortar joint, so this reports the FAIL
as expected and correct, the same carve out the playbook gives a polished
or flat manufactured face.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_stream_water"
CLS_READ = lib.class_of(STEM, GAME)
CLS = "glass"
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    col_mean = lum.mean(axis=0)
    row_mean = lum.mean(axis=1)
    print(f"col mean range {col_mean.min():.3f} to {col_mean.max():.3f}, "
          f"row mean range {row_mean.min():.3f} to {row_mean.max():.3f} (no directional structure)")
    print(f"class read back from the bake: {CLS_READ}; used here: {CLS} (a liquid tile)")

    # Gentle ripples: two loose, slow moving wave trains at different
    # angles and scales, the kind of interference pattern a stream's own
    # surface shows, plus a fine capillary ripple riding on top.
    swell_a = lib.fbm(SIZE, base_cells=5, octaves=2, seed=2801, gain=0.55)
    swell_b = lib.fbm(SIZE, base_cells=8, octaves=2, seed=2802, gain=0.5)
    ripple = lib.fbm(SIZE, base_cells=28, octaves=3, seed=2803, gain=0.55)

    raw = 0.55 * swell_a + 0.30 * swell_b + 0.15 * ripple
    # Kept in a narrow band, not stretched to the class depth: a stream's
    # surface is nearly flat, never a mortar joint.
    height = lib.band(raw, half_width=0.09)
    print(f"height sd {height.std():.4f}")

    # Smoothness stays high and even, a wet surface, with the ripple's own
    # crests reading a touch smoother than its troughs and the art's own
    # dither folded in as a mild extra lift so the glints are not perfectly
    # uniform.
    dither = lib.normalise01(lib.upscale(lum, smooth=True))
    smooth = 0.75 + 0.10 * zscore(height) + 0.06 * zscore(dither)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 6.0
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
