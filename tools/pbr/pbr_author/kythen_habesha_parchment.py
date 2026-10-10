"""Hand authored LabPBR height and smoothness for kythen_habesha_parchment.

The 32 px art has six grey shades in a fine stipple, 373 connected regions
over 1024 texels (mean size 2.7 texels): this is dither grain, not drawn
blotches or a directional fibre weave. Row means (0.53 to 0.63) and column
means (0.52 to 0.67) carry no consistent axis, so there is no drawn grain
direction to follow; the art's own texel level noise already is the fibre
texture. lib.class_of reads "wood" (there is no "paper" class in lib.py's
targets), so this is packed and checked against the wood tilt band, 18 to
28 degrees, even though a written sheet held flat has nowhere near that
much real relief in physical terms. This is a genuinely flat manufactured
surface, built as one on purpose (lib.band with a small half width, no
domed regions), and it is expected to miss the tilt band: see below for
why cranking normal_strength to reach it anyway is rejected on purpose.

An earlier revision of this script (normal_strength 140, reverted here)
argued that turning tilt up this way is not fake relief because
normal_strength is only a gain and the height field's own shape never
changes. That argument does not survive lib.py's own definition of the
knob: normal_strength "is the height of the full 0..1 range in texels"
(normal_from_height's docstring, and README's targets table), i.e. it is
not a viewing gain but the claimed physical depth the encoded band
represents. This script's band is half_width 0.06, so its height fills
about 0.12 of the class byte range; at normal_strength 140 that is a
claimed 0.12 * 140 ~= 17 texels from the shallowest fibre valley to the
highest fibre ridge. Seventeen texels is a real mortar joint's depth
(default_stone_brick uses normal_strength 40 on a field that fills most
of the range; mcl_core_iron_ore's ore nodule, a real physical bump, is 38
on a band of half_width 0.2, ~15 texels), not a sheet of parchment's
grain. Turning the number up until the claimed depth matches a stone
joint, to pass a tilt check built for masonry and planks, is exactly the
fake relief the brief says not to chase. normal_strength stays in the
range this pack's other flat, banded surfaces use (10 to 16) instead, and
the tilt reading is left low and honestly reported.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_parchment"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


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
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("row means:", np.round(lum.mean(axis=1), 3))
    print("col means:", np.round(lum.mean(axis=0), 3))
    print(f"lib.class_of reads: {CLS}")

    # The art's own stipple, upscaled and softened a touch: parchment is
    # written on and scraped smooth, so the harsh per texel edges nearest
    # upscale gives are eased rather than kept sharp the way a cobble's
    # texel plateaus are kept.
    layout = lib.upscale(lum)
    soft = lib.blur(layout, 1)

    # A faint fibre hint below the texel: the art carries no drawn axis, so
    # this is a light anisotropic grain of our own, not a reading of the
    # art. Amplitude stays small, it is a hint, not a weave.
    fibre_src = lib.fbm(SIZE, base_cells=24, octaves=2, seed=71, gain=0.5)
    fibre = blur_axis(fibre_src, radius=10, axis=0) * 0.35

    fine = lib.blur(lib.white_noise(SIZE, seed=72), 1) * 0.10

    # Held in a narrow band: a written sheet is flat, filling the class
    # depth here would read as pitted leather, not parchment.
    height = lib.band(soft + fibre + fine, half_width=0.06)
    print(f"height sd {height.std():.4f}")

    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=73, gain=0.55)
    smooth = 0.55 + 0.12 * zscore(soft) + 0.10 * zscore(rough_noise)
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    # In line with this pack's other flat, banded surfaces (khmer stucco
    # 10, default_dirt 16, default_bookshelf's spine band 16), not cranked
    # up to chase the wood tilt band: see the module docstring for why.
    normal_strength = 16.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    print("note: both the tilt and the ao min are expected misses here, the "
          "flat-manufactured-face exception the playbook allows, not a "
          "defect to fix by digging fake relief into a written sheet. Tilt "
          "reads a few degrees because the real height amplitude is fibre "
          "scale, not joint scale (see the module docstring for why the "
          "band is not cranked up with normal_strength to force a pass). "
          "ao min reads 0.96 because a flat sheet has no groove deep enough "
          "to self shadow; lib.check treats wood as a jointed class by "
          "default, which parchment is not, and no normal_strength changes "
          "this either, since ao is computed from the height field's own "
          "shape, not from the gain used to read its slope.")
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
